package core

// Core vocabulary of the engine: handles, pools, type keys, type registries
// and object references. Depends only on Odin's core library, so any package
// can import moonhug:engine/core without importing the engine.
//
// The engine aliases core names in engine/core_exports.odin:
// - Types and procs the engine uses get an alias. engine.Handle and
//   core.Handle are the same type.
// - Global variables get no alias (Odin aliases types and procs only).
//   Access the registry maps as core.<name> or through the accessor procs.

import "base:runtime"

MAX            :: 1024
POOL_PAGE_SIZE :: 1024

Handle :: struct {
    index:      u32,
    generation: u16,
    type_key:   TypeKey,
}

_Pool_Slot :: struct($T: typeid) {
    generation: u16,
    alive:      bool,
    data:       T,
}

// Pool internals (_-prefixed fields) are private: the slot layout is an
// implementation detail that may change (e.g. SoA columns), so nothing
// outside this file touches them. Consumers hold Handles and reach data
// through pool_get / pool_iterator — see docs/Components.md for the contract.
Pool :: struct($T: typeid, $N: int = MAX) {
    _slots:         [N]_Pool_Slot(T),
    _freelist:      [N]u32,
    _free_head:     int,
    _pages:         [dynamic]^[POOL_PAGE_SIZE]_Pool_Slot(T),
    _overflow_used: u32,
    _overflow_free: [dynamic]u32,
    count:          int,
}

pool_init :: proc(p: ^Pool($T, $N)) {
    for i in 0..<N {
        p._freelist[i] = u32(i)
        p._slots[i].generation = 1
    }
    p._free_head = N - 1
    p._pages = nil
    p._overflow_used = 0
    p._overflow_free = nil
    p.count = 0
}

pool_free :: proc(p: ^Pool($T, $N)) {
    if p == nil do return
    for page in p._pages {
        if page != nil do free(page, runtime.default_allocator())
    }
    delete(p._pages)
    delete(p._overflow_free)
    p._pages = nil
    p._overflow_used = 0
    p._overflow_free = nil
    p.count = 0
}

@(private = "file")
_slot_ptr :: #force_inline proc(p: ^Pool($T, $N), index: u32) -> ^_Pool_Slot(T) {
    if index < u32(N) {
        return &p._slots[index]
    }
    ov := index - u32(N)
    if ov >= p._overflow_used do return nil
    page_idx := int(ov / POOL_PAGE_SIZE)
    if page_idx >= len(p._pages) || p._pages[page_idx] == nil do return nil
    return &p._pages[page_idx][ov % POOL_PAGE_SIZE]
}

pool_create :: proc(p: ^Pool($T, $N)) -> (Handle, ^T) {
    if p._free_head >= 0 {
        idx := p._freelist[p._free_head]
        p._free_head -= 1
        p.count += 1
        slot := &p._slots[idx]
        slot.alive = true
        // A recycled slot keeps the destroyed instance's bytes. Hand out zeroed
        // memory: loaders unmarshal IN PLACE and json:"-" fields (nested_owned,
        // owner) are never in the payload — stale values would survive. A stale
        // nested_owned=true makes every save silently skip the component.
        slot.data = {}
        handle := Handle{ index = idx, generation = slot.generation, type_key = INVALID_TYPE_KEY }
        return handle, &slot.data
    }

    context.allocator = runtime.default_allocator()
    if len(p._overflow_free) > 0 {
        idx := p._overflow_free[len(p._overflow_free) - 1]
        pop(&p._overflow_free)
        slot := _slot_ptr(p, idx)
        slot.alive = true
        slot.data = {}
        p.count += 1
        return Handle{ index = idx, generation = slot.generation, type_key = INVALID_TYPE_KEY }, &slot.data
    }

    if p._pages == nil {
        p._pages = make([dynamic]^[POOL_PAGE_SIZE]_Pool_Slot(T), 0, 4)
    }
    ov := p._overflow_used
    page_idx := int(ov / POOL_PAGE_SIZE)
    slot_in_page := int(ov % POOL_PAGE_SIZE)
    for len(p._pages) <= page_idx {
        page := new([POOL_PAGE_SIZE]_Pool_Slot(T))
        append(&p._pages, page)
    }
    slot := &p._pages[page_idx][slot_in_page]
    slot.generation = 1
    slot.alive = true
    slot.data = {}
    p._overflow_used += 1
    idx := u32(N) + ov
    p.count += 1
    return Handle{ index = idx, generation = slot.generation, type_key = INVALID_TYPE_KEY }, &slot.data
}

pool_destroy :: proc(p: ^Pool($T, $N), h: Handle) {
    assert(pool_valid(p, h), "invalid handle")
    if h.index < u32(N) {
        slot := &p._slots[h.index]
        slot.alive      = false
        slot.generation += 1
        p._free_head += 1
        p._freelist[p._free_head] = h.index
        p.count -= 1
        return
    }
    slot := _slot_ptr(p, h.index)
    slot.alive      = false
    slot.generation += 1
    context.allocator = runtime.default_allocator()
    if p._overflow_free == nil {
        p._overflow_free = make([dynamic]u32, 0, 16)
    }
    append(&p._overflow_free, h.index)
    p.count -= 1
}

pool_get :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    if !pool_valid(pool, handle) do return nil
    slot := _slot_ptr(pool, handle.index)
    return slot != nil ? &slot.data : nil
}
pool_get_assert :: proc(pool: ^Pool($T, $N), handle: Handle) -> ^T {
    assert(pool_valid(pool, handle))
    return &_slot_ptr(pool, handle.index).data
}

pool_valid :: proc(p: ^Pool($T, $N), h: Handle) -> bool {
    if p == nil do return false
    slot := _slot_ptr(p, h.index)
    if slot == nil do return false
    return slot.alive && slot.generation == h.generation
}

// Iteration over alive components:
//
//	it := pool_iterator(pool)
//	for comp, h in pool_next(&it) { ... }
//
// A nil pool yields an empty iterator (no caller-side guard). The handle
// carries INVALID_TYPE_KEY — pools don't know their TypeKey, callers stamp
// it when they need a typed handle. Destroying any component (including the
// current one) mid-iteration is safe; components created mid-iteration may
// or may not be visited.
Pool_Iterator :: struct($T: typeid, $N: int) {
    pool:  ^Pool(T, N),
    index: int,
}

pool_iterator :: proc(p: ^Pool($T, $N)) -> Pool_Iterator(T, N) {
    return {pool = p}
}

pool_next :: proc(it: ^Pool_Iterator($T, $N)) -> (data: ^T, h: Handle, ok: bool) {
    if it.pool == nil do return
    total := N + int(it.pool._overflow_used)
    for it.index < total {
        i := it.index
        it.index += 1
        slot := _slot_ptr(it.pool, u32(i))
        if slot != nil && slot.alive {
            return &slot.data, Handle{ index = u32(i), generation = slot.generation, type_key = INVALID_TYPE_KEY }, true
        }
    }
    return
}

Pool_Entry :: struct {
    pool:           rawptr,
    get_fn:         proc(pool: rawptr, handle: Handle) -> rawptr,
    valid_fn:       proc(pool: rawptr, handle: Handle) -> bool,
    create_fn:      proc(pool: rawptr) -> (Handle, rawptr),
    destroy_fn:     proc(pool: rawptr, handle: Handle),
}

pool_make_entry :: proc(p: ^Pool($T, $N)) -> Pool_Entry {
    return Pool_Entry{
        pool = p,
        get_fn = proc(pool: rawptr, handle: Handle) -> rawptr {
            p := cast(^Pool(T, N))pool
            return pool_get(p, handle)
        },
        valid_fn = proc(pool: rawptr, handle: Handle) -> bool {
            p := cast(^Pool(T, N))pool
            return pool_valid(p, handle)
        },
        create_fn = proc(pool: rawptr) -> (Handle, rawptr) {
            p := cast(^Pool(T, N))pool
            return pool_create(p)
        },
        destroy_fn = proc(pool: rawptr, handle: Handle) {
            p := cast(^Pool(T, N))pool
            pool_destroy(p, handle)
        },
    }
}
