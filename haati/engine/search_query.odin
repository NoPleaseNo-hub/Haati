package engine

import "core:strings"

MAX_SEARCH_TERMS :: 8

Prepared_Search_Query :: struct {
	raw_lower:  string,
	norm:       string,
	terms:      [MAX_SEARCH_TERMS]string,
	term_norms: [MAX_SEARCH_TERMS]string,
	term_count: int,
}

_is_search_delim :: #force_inline proc(ch: u8) -> bool {
	return ch == '_' || ch == '-' || ch == ' ' || ch == '.' || ch == '/' || ch == '\\'
}

// Lowercases ASCII characters and strips common path/identifier delimiters
// (`'_'`, `'-'`, `' '`, `'.'`, `'/'`, `'\\'`) so e.g. `"node_3.odin"` -> `"node3odin"`.
normalize_search_key :: proc(s: string, allocator := context.temp_allocator) -> (raw_lower: string, norm: string) {
	if len(s) == 0 do return "", ""
	has_non_ascii := false
	for i in 0 ..< len(s) {
		if s[i] >= 0x80 {
			has_non_ascii = true
			break
		}
	}
	if !has_non_ascii {
		lower_buf := make([]u8, len(s), allocator)
		norm_buf := make([dynamic]u8, 0, len(s), allocator)
		for i in 0 ..< len(s) {
			ch := s[i]
			if ch >= 'A' && ch <= 'Z' do ch += 'a' - 'A'
			lower_buf[i] = ch
			if !_is_search_delim(ch) {
				append(&norm_buf, ch)
			}
		}
		return string(lower_buf), string(norm_buf[:])
	}

	raw_lower = strings.to_lower(s, allocator)
	norm_buf := make([dynamic]u8, 0, len(raw_lower), allocator)
	for i in 0 ..< len(raw_lower) {
		ch := raw_lower[i]
		if !_is_search_delim(ch) {
			append(&norm_buf, ch)
		}
	}
	return raw_lower, string(norm_buf[:])
}

// Normalizes `s` into stack buffers when ASCII and small enough, falling back to
// `allocator` only for very long or non-ASCII strings.
@(private = "file")
_normalize_field_fast :: proc(s: string, lo_stack, norm_stack: []u8) -> (lo, norm: string) {
	if len(s) == 0 do return "", ""
	if len(s) <= len(lo_stack) {
		has_non_ascii := false
		for i in 0 ..< len(s) {
			if s[i] >= 0x80 {
				has_non_ascii = true
				break
			}
		}
		if !has_non_ascii {
			n_len := 0
			for i in 0 ..< len(s) {
				ch := s[i]
				if ch >= 'A' && ch <= 'Z' do ch += 'a' - 'A'
				lo_stack[i] = ch
				if !_is_search_delim(ch) {
					norm_stack[n_len] = ch
					n_len += 1
				}
			}
			return string(lo_stack[:len(s)]), string(norm_stack[:n_len])
		}
	}
	return normalize_search_key(s, context.temp_allocator)
}

// Parses `query` once per frame into lowercased, whitespace-split, delimiter-normalized tokens.
prepare_search_query :: proc(query: string, allocator := context.temp_allocator) -> Prepared_Search_Query {
	trimmed := strings.trim_space(query)
	if len(trimmed) == 0 do return {}

	pq: Prepared_Search_Query
	pq.raw_lower, pq.norm = normalize_search_key(trimmed, allocator)

	it := pq.raw_lower
	for field in strings.fields_iterator(&it) {
		if pq.term_count >= MAX_SEARCH_TERMS do break
		idx := pq.term_count
		pq.terms[idx] = field
		_, pq.term_norms[idx] = normalize_search_key(field, allocator)
		pq.term_count += 1
	}
	return pq
}

// Returns true when `new_query` is a strict narrowing refinement of `old_query`,
// allowing indexed search callers to filter the previous result slice instead of rescanning.
can_narrow_search_query :: proc(old_query, new_query: string) -> bool {
	old_t := strings.trim_space(old_query)
	new_t := strings.trim_space(new_query)
	if len(old_t) == 0 || len(new_t) <= len(old_t) do return false

	old_lo := strings.to_lower(old_t, context.temp_allocator)
	new_lo := strings.to_lower(new_t, context.temp_allocator)
	return strings.contains(new_lo, old_lo)
}

// Lock-free, zero-allocation worker-thread predicate over pre-computed lowercase/norm keys.
search_match_cached :: proc(
	name_lower: string,
	name_norm: string,
	pq: ^Prepared_Search_Query,
	path_lower := "",
	require_primary_hit := true,
) -> bool {
	if pq == nil || len(pq.raw_lower) == 0 do return true

	// 1. Direct substring on primary name (or full path when query includes path separators).
	if strings.contains(name_lower, pq.raw_lower) do return true
	if len(path_lower) > 0 &&
	   (!require_primary_hit || strings.contains_rune(pq.raw_lower, '/') || strings.contains_rune(pq.raw_lower, '\\')) &&
	   strings.contains(path_lower, pq.raw_lower) {
		return true
	}

	// 2. Delimiter-stripped normalized match on primary name (e.g. "node3" -> "node_3.odin").
	if len(pq.norm) > 0 && strings.contains(name_norm, pq.norm) do return true

	// 3. Multi-word conjunction across primary name and optional path.
	if pq.term_count > 1 {
		any_name_match := false
		for i in 0 ..< pq.term_count {
			t := pq.terms[i]
			tn := pq.term_norms[i]
			name_hit := strings.contains(name_lower, t) || (len(tn) > 0 && strings.contains(name_norm, tn))
			if name_hit do any_name_match = true
			matched := name_hit || (len(path_lower) > 0 && strings.contains(path_lower, t))
			if !matched do return false
		}
		return !require_primary_hit || any_name_match
	}

	return false
}

// Evaluates multi-term conjunction across `primary` and `secondaries` with delimiter
// normalization and returns a relevance tier:
//   4 = empty query, or primary exact/prefix match
//   3 = all query terms matched `primary`
//   2 = cross-field match with >= 1 term hitting `primary`
//   1 = secondary-only match (only returned when `require_primary_hit == false`)
//   0 = no match
search_rank_fields :: proc(
	pq: ^Prepared_Search_Query,
	require_primary_hit: bool,
	primary: string,
	secondaries: ..string,
) -> int {
	if pq == nil || len(pq.raw_lower) == 0 do return 4
	if pq.term_count == 0 do return 4

	lo_stack:   [512]u8 = ---
	norm_stack: [512]u8 = ---
	prim_lo, prim_norm := _normalize_field_fast(primary, lo_stack[:], norm_stack[:])

	// Fast full-query exact/prefix check on primary first.
	prim_exact_or_prefix := (prim_lo == pq.raw_lower || strings.has_prefix(prim_lo, pq.raw_lower)) ||
		(len(pq.norm) > 0 && (prim_norm == pq.norm || strings.has_prefix(prim_norm, pq.norm)))
	if prim_exact_or_prefix do return 4

	// Check which terms hit primary, tracking misses to test against `secondaries`.
	term_hit_primary: [MAX_SEARCH_TERMS]bool
	prim_hits := 0
	for i in 0 ..< pq.term_count {
		t := pq.terms[i]
		tn := pq.term_norms[i]
		if strings.contains(prim_lo, t) || (len(tn) > 0 && strings.contains(prim_norm, tn)) {
			term_hit_primary[i] = true
			prim_hits += 1
		}
	}

	if prim_hits == pq.term_count do return 3
	if require_primary_hit && prim_hits == 0 {
		// Allow explicit path queries like "assets/foo" if caller passed secondaries matching the whole raw path.
		if !(strings.contains_rune(pq.raw_lower, '/') || strings.contains_rune(pq.raw_lower, '\\')) {
			return 0
		}
	}

	// Verify remaining terms match at least one secondary field.
	for i in 0 ..< pq.term_count {
		if term_hit_primary[i] do continue
		t := pq.terms[i]
		tn := pq.term_norms[i]
		hit_sec := false
		for sec in secondaries {
			if len(sec) == 0 do continue
			sec_lo, sec_norm := _normalize_field_fast(sec, lo_stack[:], norm_stack[:])
			if strings.contains(sec_lo, t) || (len(tn) > 0 && strings.contains(sec_norm, tn)) {
				hit_sec = true
				break
			}
		}
		if !hit_sec do return 0
	}

	if prim_hits > 0 do return 2
	if !require_primary_hit do return 1
	// Reached only on explicit slash path match in secondaries when require_primary_hit is true.
	for sec in secondaries {
		if len(sec) == 0 do continue
		sec_lo, _ := _normalize_field_fast(sec, lo_stack[:], norm_stack[:])
		if strings.contains(sec_lo, pq.raw_lower) do return 1
	}
	return 0
}

// Matches when every query term appears in `primary` or any of `secondaries`.
search_match_fields :: proc(pq: ^Prepared_Search_Query, primary: string, secondaries: ..string) -> bool {
	return search_rank_fields(pq, false, primary, ..secondaries) > 0
}

// Matches when every query term appears in `primary` or `secondaries`, AND at least one
// term appears in `primary` (prevents folder/category names alone from flooding results).
search_match_fields_primary :: proc(pq: ^Prepared_Search_Query, primary: string, secondaries: ..string) -> bool {
	return search_rank_fields(pq, true, primary, ..secondaries) > 0
}

// Single-string convenience matcher using delimiter-normalized token conjunction.
search_match_prepared :: proc(text: string, pq: ^Prepared_Search_Query) -> bool {
	return search_rank_fields(pq, true, text) > 0
}
