package editor

import "base:runtime"
import "core:strings"
import "core:sync"
import im "haati:external/odin-imgui"
import "menu"
import "haati:editor/icons"
import "haati:editor/widgets"
import wnd "haati:editor/window"

MAX_OUTPUT_LINES :: 2000

// Off means the view stays where you scrolled it while a build keeps writing,
// which is the only way to read an error that has scrolled past.
output_follow_tail := true

_output_lines: [dynamic]string
_output_mutex: sync.Mutex
_output_last_count: int
_output_revision: u64 = 1
_output_cached_rev: u64 = 0
_output_cached_buf: [dynamic]u8

output_view_append :: proc(stdout, stderr: []byte) {
	if len(stdout) == 0 && len(stderr) == 0 do return
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc

	append_lines :: proc(lines: ^[dynamic]string, data: []byte, prefix: string) {
		if len(data) == 0 do return
		s := transmute(string)(data)
		for {
			idx := strings.index_byte(s, '\n')
			if idx >= 0 {
				line := s[:idx]
				if prefix != "" {
					line = strings.concatenate({prefix, line}, context.temp_allocator)
				}
				append(lines, strings.clone(line))
				s = s[idx + 1:]
			} else {
				if len(s) > 0 {
					if prefix != "" {
						s = strings.concatenate({prefix, s}, context.temp_allocator)
					}
					append(lines, strings.clone(s))
				}
				break
			}
		}
	}

	append_lines(&_output_lines, stdout, "")
	append_lines(&_output_lines, stderr, "[stderr] ")

	for len(_output_lines) > MAX_OUTPUT_LINES {
		delete(_output_lines[0])
		ordered_remove(&_output_lines, 0)
	}
	_output_revision += 1
}

output_view_append_line :: proc(line: string) {
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	append(&_output_lines, strings.clone(line))
	for len(_output_lines) > MAX_OUTPUT_LINES {
		delete(_output_lines[0])
		ordered_remove(&_output_lines, 0)
	}
	_output_revision += 1
}

output_view_clear :: proc() {
	sync.mutex_lock(&_output_mutex)
	defer sync.mutex_unlock(&_output_mutex)
	prev_alloc := context.allocator
	context.allocator = runtime.default_allocator()
	defer context.allocator = prev_alloc
	for line in _output_lines {
		delete(line)
	}
	clear(&_output_lines)
	_output_last_count = 0
	_output_revision += 1
}

draw_output_view :: proc() {
	if !wnd.begin(icons.TITLE_OUTPUT, &menu.show_output, {.NoCollapse}) {
		im.End()
		return
	}
	defer im.End()

	wnd.decorate_floating_window(icons.TITLE_OUTPUT, &menu.show_output)

	if im.Button("Clear") {
		output_view_clear()
	}
	im.SameLine()
	filter_toggle_button("Follow", &output_follow_tail)
	im.SameLine()
	widgets.textf("Last run stdout/stderr (max %d lines)", MAX_OUTPUT_LINES)
	im.Separator()

	// Cache the joined buffer on _output_revision changes instead of joining up
	// to MAX_OUTPUT_LINES strings every UI frame.
	sync.mutex_lock(&_output_mutex)
	n := len(_output_lines)
	if _output_cached_rev != _output_revision {
		context.allocator = runtime.default_allocator()
		clear(&_output_cached_buf)
		for line, idx in _output_lines {
			if idx > 0 do append(&_output_cached_buf, '\n')
			append(&_output_cached_buf, ..transmute([]u8)line)
		}
		append(&_output_cached_buf, 0)
		_output_cached_rev = _output_revision
	}
	sync.mutex_unlock(&_output_mutex)

	if len(_output_cached_buf) == 0 {
		context.allocator = runtime.default_allocator()
		append(&_output_cached_buf, 0)
	}

	if output_follow_tail && n > _output_last_count && n > 0 {
		// New output: pin the input's internal child (the NEXT window imgui
		// creates) to the bottom. x = -1 leaves horizontal scroll alone.
		im.SetNextWindowScroll(im.Vec2{-1, max(f32)})
	}
	_output_last_count = n
	widgets.readonly_multiline_buf("##output_text", _output_cached_buf[:], {-1, -1})
}
