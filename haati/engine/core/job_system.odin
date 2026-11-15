package core

// Work-stealing multi-core job system & parallel-for dispatcher.
// Each worker (up to MAX_WORKER_THREADS) owns a local ring deque and steals from
// siblings + the global overflow queue before sleeping. Calling threads actively
// assist during `job_wait` and `job_parallel_for`, guaranteeing forward progress
// without deadlocks even on nested waits, and propagating `context.user_ptr`.

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import sysinfo "core:sys/info"
import "core:thread"

MAX_QUEUED_JOBS      :: 4096
MAX_WORKER_THREADS   :: 64
MAX_PAR_BATCHES      :: 64
PER_WORKER_QUEUE_CAP :: 512

Job_Proc          :: #type proc(user_data: rawptr)
Parallel_For_Proc :: #type proc(start_idx, end_idx: int, user_data: rawptr)

Job_Counter :: struct {
	remaining: i32,
}

Job_Desc :: struct {
	fn:           Job_Proc,
	user_data:    rawptr,
	counter:      ^Job_Counter,
	ctx_user_ptr: rawptr,
}

Job_Telemetry_Snapshot :: struct {
	num_workers:      int,
	total_jobs:       u64,
	total_steals:     u64,
	main_assist_jobs: u64,
	worker_jobs:      [MAX_WORKER_THREADS]u64,
}

@(private = "file")
_Worker_Queue :: struct {
	mutex: sync.Mutex,
	head:  u32,
	tail:  u32,
	count: u32,
	ring:  [PER_WORKER_QUEUE_CAP]Job_Desc,
}

@(private = "file")
_Job_System_State :: struct {
	mutex:               sync.Mutex,
	cond:                sync.Cond,
	initialized:         bool,
	stopping:            bool,
	head:                u32,
	tail:                u32,
	count:               u32,
	queue:               [MAX_QUEUED_JOBS]Job_Desc,
	workers:             [MAX_WORKER_THREADS]^thread.Thread,
	wqueues:             [MAX_WORKER_THREADS]_Worker_Queue,
	num_workers:         int,
	sleeping_workers:    i32,
	rr_cursor:           u32,
	total_jobs_executed: u64,
	total_steals:        u64,
	slot_jobs:           [MAX_WORKER_THREADS + 1]u64, // 0 = caller/main, 1..64 = workers
}

@(private = "file")
_jobs: _Job_System_State

@(thread_local, private = "file")
_tls_worker_slot: int // 0 on main/external threads, 1..num_workers inside worker threads

job_current_worker_index :: proc() -> int {
	return _tls_worker_slot
}

job_system_telemetry :: proc() -> Job_Telemetry_Snapshot {
	snap: Job_Telemetry_Snapshot
	snap.num_workers = _jobs.num_workers
	snap.total_jobs = intrinsics.atomic_load_explicit(&_jobs.total_jobs_executed, .Relaxed)
	snap.total_steals = intrinsics.atomic_load_explicit(&_jobs.total_steals, .Relaxed)
	snap.main_assist_jobs = intrinsics.atomic_load_explicit(&_jobs.slot_jobs[0], .Relaxed)
	for i in 0 ..< MAX_WORKER_THREADS {
		snap.worker_jobs[i] = intrinsics.atomic_load_explicit(&_jobs.slot_jobs[i + 1], .Relaxed)
	}
	return snap
}

job_system_reset_telemetry :: proc() {
	intrinsics.atomic_store_explicit(&_jobs.total_jobs_executed, 0, .Relaxed)
	intrinsics.atomic_store_explicit(&_jobs.total_steals, 0, .Relaxed)
	for i in 0 ..< MAX_WORKER_THREADS + 1 {
		intrinsics.atomic_store_explicit(&_jobs.slot_jobs[i], 0, .Relaxed)
	}
}

@(private = "file")
_wqueue_push :: proc(wq: ^_Worker_Queue, job: Job_Desc) -> bool {
	sync.mutex_lock(&wq.mutex)
	defer sync.mutex_unlock(&wq.mutex)
	if wq.count >= PER_WORKER_QUEUE_CAP do return false
	wq.ring[wq.tail] = job
	wq.tail = (wq.tail + 1) % PER_WORKER_QUEUE_CAP
	wq.count += 1
	return true
}

@(private = "file")
_wqueue_pop_local :: proc(wq: ^_Worker_Queue) -> (job: Job_Desc, ok: bool) {
	sync.mutex_lock(&wq.mutex)
	if wq.count > 0 {
		// LIFO on own deque for cache locality
		wq.tail = (wq.tail + PER_WORKER_QUEUE_CAP - 1) % PER_WORKER_QUEUE_CAP
		job = wq.ring[wq.tail]
		wq.count -= 1
		ok = true
	}
	sync.mutex_unlock(&wq.mutex)
	return
}

@(private = "file")
_wqueue_steal_front :: proc(wq: ^_Worker_Queue) -> (job: Job_Desc, ok: bool) {
	if !sync.mutex_try_lock(&wq.mutex) {
		return {}, false
	}
	if wq.count > 0 {
		job = wq.ring[wq.head]
		wq.head = (wq.head + 1) % PER_WORKER_QUEUE_CAP
		wq.count -= 1
		ok = true
	}
	sync.mutex_unlock(&wq.mutex)
	return
}

@(private = "file")
_global_pop :: proc() -> (job: Job_Desc, ok: bool) {
	sync.mutex_lock(&_jobs.mutex)
	if _jobs.count > 0 {
		job = _jobs.queue[_jobs.head]
		_jobs.head = (_jobs.head + 1) % MAX_QUEUED_JOBS
		_jobs.count -= 1
		ok = true
	}
	sync.mutex_unlock(&_jobs.mutex)
	return
}

@(private = "file")
_execute_job_desc :: proc(job: Job_Desc, slot_idx: int) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	prev_user := context.user_ptr
	context.user_ptr = job.ctx_user_ptr
	if job.fn != nil {
		job.fn(job.user_data)
	}
	context.user_ptr = prev_user

	if job.counter != nil {
		intrinsics.atomic_sub(&job.counter.remaining, 1)
	}
	intrinsics.atomic_add_explicit(&_jobs.total_jobs_executed, 1, .Relaxed)
	if slot_idx >= 0 && slot_idx <= MAX_WORKER_THREADS {
		intrinsics.atomic_add_explicit(&_jobs.slot_jobs[slot_idx], 1, .Relaxed)
	}
}

@(private = "file")
_try_steal_any_worker :: proc(self_worker_idx: int, n_workers: int) -> (job: Job_Desc, ok: bool, stolen: bool) {
	if n_workers <= 0 do return {}, false, false
	start := self_worker_idx >= 0 ? self_worker_idx : int(intrinsics.atomic_add_explicit(&_jobs.rr_cursor, 1, .Relaxed)) % n_workers
	for off in 0 ..< n_workers {
		target := (start + off) % n_workers
		if target == self_worker_idx do continue
		if j, got := _wqueue_steal_front(&_jobs.wqueues[target]); got {
			return j, true, true
		}
	}
	return {}, false, false
}

@(private = "file")
_any_wqueue_nonempty :: proc(n_workers: int) -> bool {
	for i in 0 ..< n_workers {
		if intrinsics.atomic_load_explicit(&_jobs.wqueues[i].count, .Relaxed) > 0 {
			return true
		}
	}
	return false
}

@(private = "file")
_worker_proc :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	slot := t.user_index
	if slot < 1 || slot > MAX_WORKER_THREADS do slot = 1
	_tls_worker_slot = slot
	w_idx := slot - 1

	for {
		n_workers := _jobs.num_workers

		// 1. Pop from own local deque (LIFO)
		if job, ok := _wqueue_pop_local(&_jobs.wqueues[w_idx]); ok {
			_execute_job_desc(job, slot)
			free_all(context.temp_allocator)
			continue
		}

		// 2. Pop from global overflow queue
		if job, ok := _global_pop(); ok {
			_execute_job_desc(job, slot)
			free_all(context.temp_allocator)
			continue
		}

		// 3. Steal from sibling worker deques (FIFO)
		if job, ok, _ := _try_steal_any_worker(w_idx, n_workers); ok {
			intrinsics.atomic_add_explicit(&_jobs.total_steals, 1, .Relaxed)
			_execute_job_desc(job, slot)
			free_all(context.temp_allocator)
			continue
		}

		// 3b. Brief pause-loop spin before paying condition-variable lock/wait cost
		spun_job := false
		for _ in 0 ..< 32 {
			if _jobs.stopping do break
			if job, ok := _wqueue_pop_local(&_jobs.wqueues[w_idx]); ok {
				_execute_job_desc(job, slot)
				free_all(context.temp_allocator)
				spun_job = true
				break
			}
			if job, ok, _ := _try_steal_any_worker(w_idx, n_workers); ok {
				intrinsics.atomic_add_explicit(&_jobs.total_steals, 1, .Relaxed)
				_execute_job_desc(job, slot)
				free_all(context.temp_allocator)
				spun_job = true
				break
			}
			if intrinsics.atomic_load_explicit(&_jobs.count, .Relaxed) > 0 {
				if job, ok := _global_pop(); ok {
					_execute_job_desc(job, slot)
					free_all(context.temp_allocator)
					spun_job = true
					break
				}
			}
			intrinsics.cpu_relax()
		}
		if spun_job do continue

		// 4. Wait until work arrives or shutdown requested (SeqCst sleeping_workers prevents lost wakeups)
		sync.mutex_lock(&_jobs.mutex)
		for _jobs.count == 0 && !_jobs.stopping && !_any_wqueue_nonempty(_jobs.num_workers) {
			intrinsics.atomic_add_explicit(&_jobs.sleeping_workers, 1, .Seq_Cst)
			if _jobs.count == 0 && !_jobs.stopping && !_any_wqueue_nonempty(_jobs.num_workers) {
				sync.cond_wait(&_jobs.cond, &_jobs.mutex)
			}
			intrinsics.atomic_sub_explicit(&_jobs.sleeping_workers, 1, .Seq_Cst)
		}
		if _jobs.stopping && _jobs.count == 0 && !_any_wqueue_nonempty(_jobs.num_workers) {
			sync.mutex_unlock(&_jobs.mutex)
			break
		}
		sync.mutex_unlock(&_jobs.mutex)
	}
	_tls_worker_slot = 0
}

cpu_logical_core_count :: proc() -> int {
	_, logical, ok := sysinfo.cpu_core_count()
	if ok && logical > 0 do return logical
	return 4
}

job_system_init :: proc(requested_workers: int = 0) {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	sync.mutex_lock(&_jobs.mutex)
	if _jobs.initialized {
		sync.mutex_unlock(&_jobs.mutex)
		return
	}
	_jobs.initialized = true
	_jobs.stopping = false
	_jobs.sleeping_workers = 0
	_jobs.head = 0
	_jobs.tail = 0
	_jobs.count = 0
	for i in 0 ..< MAX_WORKER_THREADS {
		_jobs.wqueues[i].head = 0
		_jobs.wqueues[i].tail = 0
		_jobs.wqueues[i].count = 0
	}

	n := requested_workers
	if n <= 0 {
		n = clamp(cpu_logical_core_count() - 1, 2, MAX_WORKER_THREADS)
	} else {
		n = clamp(n, 1, MAX_WORKER_THREADS)
	}
	_jobs.num_workers = n
	sync.mutex_unlock(&_jobs.mutex)

	for i in 0 ..< n {
		t := thread.create(_worker_proc)
		_jobs.workers[i] = t
		if t != nil {
			t.user_index = i + 1
			thread.start(t)
		}
	}
}

job_system_shutdown :: proc() {
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	sync.mutex_lock(&_jobs.mutex)
	if !_jobs.initialized {
		sync.mutex_unlock(&_jobs.mutex)
		return
	}
	_jobs.stopping = true
	n := _jobs.num_workers
	sync.cond_broadcast(&_jobs.cond)
	sync.mutex_unlock(&_jobs.mutex)

	for i in 0 ..< n {
		if _jobs.workers[i] != nil {
			thread.destroy(_jobs.workers[i])
			_jobs.workers[i] = nil
		}
	}

	sync.mutex_lock(&_jobs.mutex)
	_jobs.initialized = false
	_jobs.num_workers = 0
	_jobs.sleeping_workers = 0
	_jobs.head = 0
	_jobs.tail = 0
	_jobs.count = 0
	for i in 0 ..< MAX_WORKER_THREADS {
		_jobs.wqueues[i].head = 0
		_jobs.wqueues[i].tail = 0
		_jobs.wqueues[i].count = 0
	}
	sync.mutex_unlock(&_jobs.mutex)
}

job_system_worker_count :: proc() -> int {
	return _jobs.num_workers
}

@(private = "file")
_try_execute_one_job :: proc() -> bool {
	slot := _tls_worker_slot
	n_workers := _jobs.num_workers

	if slot >= 1 && slot <= MAX_WORKER_THREADS {
		if job, ok := _wqueue_pop_local(&_jobs.wqueues[slot - 1]); ok {
			_execute_job_desc(job, slot)
			return true
		}
	}

	if job, ok := _global_pop(); ok {
		_execute_job_desc(job, slot)
		return true
	}

	self_w := slot >= 1 ? (slot - 1) : -1
	if job, ok, _ := _try_steal_any_worker(self_w, n_workers); ok {
		if slot >= 1 {
			intrinsics.atomic_add_explicit(&_jobs.total_steals, 1, .Relaxed)
		}
		_execute_job_desc(job, slot)
		return true
	}
	return false
}

@(private = "file")
_wake_one :: proc() {
	if intrinsics.atomic_load_explicit(&_jobs.sleeping_workers, .Seq_Cst) <= 0 do return
	sync.mutex_lock(&_jobs.mutex)
	sync.cond_signal(&_jobs.cond)
	sync.mutex_unlock(&_jobs.mutex)
}

@(private = "file")
_wake_all :: proc() {
	if intrinsics.atomic_load_explicit(&_jobs.sleeping_workers, .Seq_Cst) <= 0 do return
	sync.mutex_lock(&_jobs.mutex)
	sync.cond_broadcast(&_jobs.cond)
	sync.mutex_unlock(&_jobs.mutex)
}

@(private = "file")
_dispatch_job_internal :: proc(fn: Job_Proc, user_data: rawptr, counter: ^Job_Counter, wake: bool) {
	if fn == nil do return
	if !_jobs.initialized {
		job_system_init()
	}
	if counter != nil {
		intrinsics.atomic_add(&counter.remaining, 1)
	}

	job := Job_Desc{
		fn           = fn,
		user_data    = user_data,
		counter      = counter,
		ctx_user_ptr = context.user_ptr,
	}

	enqueued := false
	n_workers := _jobs.num_workers
	if n_workers > 0 && !_jobs.stopping {
		if _tls_worker_slot >= 1 && _tls_worker_slot <= n_workers {
			enqueued = _wqueue_push(&_jobs.wqueues[_tls_worker_slot - 1], job)
		} else {
			rr := intrinsics.atomic_add_explicit(&_jobs.rr_cursor, 1, .Relaxed)
			target := int(rr % u32(n_workers))
			enqueued = _wqueue_push(&_jobs.wqueues[target], job)
		}
	}

	if enqueued {
		if wake do _wake_one()
		return
	}

	// Overflow into global ring queue
	sync.mutex_lock(&_jobs.mutex)
	if !_jobs.stopping && _jobs.count < MAX_QUEUED_JOBS {
		_jobs.queue[_jobs.tail] = job
		_jobs.tail = (_jobs.tail + 1) % MAX_QUEUED_JOBS
		_jobs.count += 1
		enqueued = true
		if wake && intrinsics.atomic_load_explicit(&_jobs.sleeping_workers, .Seq_Cst) > 0 {
			sync.cond_signal(&_jobs.cond)
		}
	}
	sync.mutex_unlock(&_jobs.mutex)

	// Fallback if queue is completely saturated: execute immediately on calling thread
	if !enqueued {
		_execute_job_desc(job, _tls_worker_slot)
	}
}

job_dispatch :: proc(fn: Job_Proc, user_data: rawptr = nil, counter: ^Job_Counter = nil) {
	_dispatch_job_internal(fn, user_data, counter, true)
}

job_wait :: proc(counter: ^Job_Counter) {
	if counter == nil do return
	spin := 0
	for intrinsics.atomic_load(&counter.remaining) > 0 {
		if _try_execute_one_job() {
			spin = 0
			continue
		}
		if spin < 32 {
			intrinsics.cpu_relax()
			spin += 1
		} else {
			spin = 0
			thread.yield()
		}
	}
}

@(private = "file")
_Parallel_Batch_Item :: struct {
	fn:        Parallel_For_Proc,
	user_data: rawptr,
	start_idx: int,
	end_idx:   int,
}

@(private = "file")
_parallel_batch_thunk :: proc(raw: rawptr) {
	item := cast(^_Parallel_Batch_Item)raw
	if item != nil && item.fn != nil {
		item.fn(item.start_idx, item.end_idx, item.user_data)
	}
}

// Splits `[0 ..< count]` into batches of at least `min_batch` items, dispatches
// batches across worker threads while the calling thread executes the final batch
// and assists/steals until all batches complete.
job_parallel_for :: proc(count: int, min_batch: int, fn: Parallel_For_Proc, user_data: rawptr = nil) {
	if count <= 0 || fn == nil do return
	eff_min := max(min_batch, 1)
	if count <= eff_min {
		fn(0, count, user_data)
		return
	}
	if !_jobs.initialized {
		job_system_init()
	}

	max_batches := clamp(_jobs.num_workers + 1, 1, MAX_PAR_BATCHES)
	batch_size := max((count + max_batches - 1) / max_batches, eff_min)
	num_batches := (count + batch_size - 1) / batch_size
	if num_batches <= 1 {
		fn(0, count, user_data)
		return
	}

	items: [MAX_PAR_BATCHES]_Parallel_Batch_Item
	counter: Job_Counter
	dispatched := num_batches - 1
	for b in 0 ..< dispatched {
		s := b * batch_size
		e := min(s + batch_size, count)
		items[b] = _Parallel_Batch_Item{
			fn        = fn,
			user_data = user_data,
			start_idx = s,
			end_idx   = e,
		}
		_dispatch_job_internal(_parallel_batch_thunk, &items[b], &counter, false)
	}
	if dispatched == 1 {
		_wake_one()
	} else if dispatched > 1 {
		_wake_all()
	}

	// Execute the final batch directly on the calling thread
	last_s := (num_batches - 1) * batch_size
	fn(last_s, count, user_data)
	intrinsics.atomic_add_explicit(&_jobs.total_jobs_executed, 1, .Relaxed)
	slot := _tls_worker_slot
	if slot >= 0 && slot <= MAX_WORKER_THREADS {
		intrinsics.atomic_add_explicit(&_jobs.slot_jobs[slot], 1, .Relaxed)
	}

	job_wait(&counter)
}
