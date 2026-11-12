package core

// Lightweight work-queue & parallel-for job system (`ENGINE_AUDIT.md` Section 6.2).
// Calling threads actively assist in draining queued jobs during `job_wait` and
// `job_parallel_for`, guaranteeing forward progress without deadlocks even with
// 0 background threads or nested waits.

import "base:intrinsics"
import "base:runtime"
import "core:sync"
import "core:thread"

MAX_QUEUED_JOBS    :: 4096
MAX_WORKER_THREADS :: 8

Job_Proc          :: #type proc(user_data: rawptr)
Parallel_For_Proc :: #type proc(start_idx, end_idx: int, user_data: rawptr)

Job_Counter :: struct {
	remaining: i32,
}

Job_Desc :: struct {
	fn:        Job_Proc,
	user_data: rawptr,
	counter:   ^Job_Counter,
}

@(private = "file")
_Job_System_State :: struct {
	mutex:       sync.Mutex,
	cond:        sync.Cond,
	initialized: bool,
	stopping:    bool,
	head:        u32,
	tail:        u32,
	count:       u32,
	queue:       [MAX_QUEUED_JOBS]Job_Desc,
	workers:     [MAX_WORKER_THREADS]^thread.Thread,
	num_workers: int,
}

@(private = "file")
_jobs: _Job_System_State

@(private = "file")
_worker_proc :: proc(t: ^thread.Thread) {
	context = runtime.default_context()
	for {
		job: Job_Desc
		has_job := false

		sync.mutex_lock(&_jobs.mutex)
		for _jobs.count == 0 && !_jobs.stopping {
			sync.cond_wait(&_jobs.cond, &_jobs.mutex)
		}
		if _jobs.stopping && _jobs.count == 0 {
			sync.mutex_unlock(&_jobs.mutex)
			break
		}
		if _jobs.count > 0 {
			job = _jobs.queue[_jobs.head]
			_jobs.head = (_jobs.head + 1) % MAX_QUEUED_JOBS
			_jobs.count -= 1
			has_job = true
		}
		sync.mutex_unlock(&_jobs.mutex)

		if has_job {
			if job.fn != nil {
				job.fn(job.user_data)
			}
			if job.counter != nil {
				intrinsics.atomic_sub(&job.counter.remaining, 1)
			}
			free_all(context.temp_allocator)
		}
	}
}

job_system_init :: proc(requested_workers: int = 0) {
	sync.mutex_lock(&_jobs.mutex)
	if _jobs.initialized {
		sync.mutex_unlock(&_jobs.mutex)
		return
	}
	_jobs.initialized = true
	_jobs.stopping = false
	_jobs.head = 0
	_jobs.tail = 0
	_jobs.count = 0

	n := requested_workers
	if n <= 0 {
		n = 4
	} else {
		n = clamp(n, 1, MAX_WORKER_THREADS)
	}
	_jobs.num_workers = n
	sync.mutex_unlock(&_jobs.mutex)

	for i in 0 ..< n {
		_jobs.workers[i] = thread.create(_worker_proc)
		if _jobs.workers[i] != nil {
			thread.start(_jobs.workers[i])
		}
	}
}

job_system_shutdown :: proc() {
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
	_jobs.head = 0
	_jobs.tail = 0
	_jobs.count = 0
	sync.mutex_unlock(&_jobs.mutex)
}

job_system_worker_count :: proc() -> int {
	return _jobs.num_workers
}

@(private = "file")
_try_execute_one_job :: proc() -> bool {
	job: Job_Desc
	has_job := false

	sync.mutex_lock(&_jobs.mutex)
	if _jobs.count > 0 {
		job = _jobs.queue[_jobs.head]
		_jobs.head = (_jobs.head + 1) % MAX_QUEUED_JOBS
		_jobs.count -= 1
		has_job = true
	}
	sync.mutex_unlock(&_jobs.mutex)

	if has_job {
		if job.fn != nil {
			job.fn(job.user_data)
		}
		if job.counter != nil {
			intrinsics.atomic_sub(&job.counter.remaining, 1)
		}
		return true
	}
	return false
}

job_dispatch :: proc(fn: Job_Proc, user_data: rawptr = nil, counter: ^Job_Counter = nil) {
	if fn == nil do return
	if !_jobs.initialized {
		job_system_init()
	}
	if counter != nil {
		intrinsics.atomic_add(&counter.remaining, 1)
	}

	enqueued := false
	sync.mutex_lock(&_jobs.mutex)
	if !_jobs.stopping && _jobs.count < MAX_QUEUED_JOBS {
		_jobs.queue[_jobs.tail] = Job_Desc{
			fn        = fn,
			user_data = user_data,
			counter   = counter,
		}
		_jobs.tail = (_jobs.tail + 1) % MAX_QUEUED_JOBS
		_jobs.count += 1
		enqueued = true
		sync.cond_signal(&_jobs.cond)
	}
	sync.mutex_unlock(&_jobs.mutex)

	// Fallback if queue is full: execute immediately on calling thread
	if !enqueued {
		fn(user_data)
		if counter != nil {
			intrinsics.atomic_sub(&counter.remaining, 1)
		}
	}
}

job_wait :: proc(counter: ^Job_Counter) {
	if counter == nil do return
	for intrinsics.atomic_load(&counter.remaining) > 0 {
		if !_try_execute_one_job() {
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
// and assists with any remaining queued batches until all complete.
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

	max_batches := clamp(_jobs.num_workers + 1, 1, 16)
	batch_size := max((count + max_batches - 1) / max_batches, eff_min)
	num_batches := (count + batch_size - 1) / batch_size
	if num_batches <= 1 {
		fn(0, count, user_data)
		return
	}

	items: [16]_Parallel_Batch_Item
	counter: Job_Counter
	for b in 0 ..< num_batches - 1 {
		s := b * batch_size
		e := min(s + batch_size, count)
		items[b] = _Parallel_Batch_Item{
			fn        = fn,
			user_data = user_data,
			start_idx = s,
			end_idx   = e,
		}
		job_dispatch(_parallel_batch_thunk, &items[b], &counter)
	}

	// Execute the final batch directly on the calling thread
	last_s := (num_batches - 1) * batch_size
	fn(last_s, count, user_data)

	job_wait(&counter)
}
