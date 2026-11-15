#+build darwin, linux
package crash_journal

// POSIX Crash Journal: async-signal-safe alternate stack, signal handler,
// and libc `backtrace_symbols_fd` flushing over `crash_journal_common.odin`.

import "core:c"
import posix "core:sys/posix"

foreign import libc "system:System"

@(default_calling_convention = "c")
foreign libc {
	backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
	// Writes symbolized frames straight to an fd — the malloc-free counterpart
	// of backtrace_symbols, and the reason we can symbolize inside a handler.
	backtrace_symbols_fd :: proc(buffer: [^]rawptr, size: c.int, fd: c.int) ---
}

@(private = "file")
_posix_alt_stack: [posix.SIGSTKSZ]byte

// Installs signal handlers. Safe to call twice — the second call is a no-op.
init :: proc(version := "") {
	if _crash_common_init(version) do return

	// A stack-overflow SIGSEGV leaves no room to run the handler on the
	// faulting stack, so give it its own.
	alt := posix.stack_t{
		ss_sp    = raw_data(_posix_alt_stack[:]),
		ss_size  = c.size_t(len(_posix_alt_stack)),
		ss_flags = {},
	}
	_ = posix.sigaltstack(&alt, nil)

	act: posix.sigaction_t
	act.sa_sigaction = _crash_signal_handler
	act.sa_flags = {.SIGINFO, .ONSTACK}
	posix.sigemptyset(&act.sa_mask)
	for sig in ([?]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGFPE, .SIGABRT, SIGTRAP}) {
		posix.sigaction(sig, &act, nil)
	}
}

refresh_symbols :: proc() {}

SIGTRAP :: posix.Signal(5)

@(private = "file")
_crash_signal_handler :: proc "c" (sig: posix.Signal, info: ^posix.siginfo_t, ctx: rawptr) {
	if _crash.in_handler {
		_crash_restore_default(sig)
		posix.raise(sig)
		return
	}
	_crash.in_handler = true

	reason: string
	#partial switch sig {
	case .SIGSEGV: reason = "SIGSEGV (invalid memory reference)"
	case .SIGBUS:  reason = "SIGBUS (bad memory access)"
	case .SIGILL:  reason = "SIGILL (illegal instruction)"
	case .SIGFPE:  reason = "SIGFPE (arithmetic error)"
	case .SIGABRT: reason = "SIGABRT (abort)"
	case SIGTRAP:  reason = "SIGTRAP (failed assert or panic — message is on stderr)"
	case:          reason = "unknown signal"
	}
	addr: rawptr = info != nil ? info.si_addr : nil

	fault_pc, fault_lr := _crash_fault_pc(ctx)
	_crash_write(reason, addr, fault_pc, fault_lr)

	_crash_restore_default(sig)
	posix.raise(sig)
}

@(private = "file")
_crash_restore_default :: proc "c" (sig: posix.Signal) {
	act: posix.sigaction_t
	act.sa_handler = auto_cast posix.SIG_DFL
	posix.sigaction(sig, &act, nil)
}

@(private = "file")
_crash_open :: proc "contextless" (p: [^]byte, plen: int) -> posix.FD {
	if plen <= 0 do return -1
	return posix.open(cstring(p),
		{.WRONLY, .CREAT, .TRUNC}, {.IWUSR, .IRUSR, .IRGRP, .IROTH})
}

@(private = "package")
_os_epoch_sec :: proc "contextless" () -> (i64, bool) {
	ts: posix.timespec
	if posix.clock_gettime(.REALTIME, &ts) == .OK {
		return i64(ts.tv_sec), true
	}
	return 0, false
}

@(private = "package")
_os_flush_and_stack :: proc "contextless" (fault_pc: rawptr, fault_lr: rawptr) {
	_w("stack:\n")
	fd := _crash_open(raw_data(_crash.path[:]), _crash.path_len)
	fd_last := _crash_open(raw_data(_crash.last_path[:]), _crash.last_path_len)
	if fd < 0 && fd_last < 0 do return
	defer if fd >= 0 do posix.close(fd)
	defer if fd_last >= 0 do posix.close(fd_last)

	if _crash.out_len > 0 {
		if fd >= 0 do _ = posix.write(fd, raw_data(_crash.out_buf[:]), c.size_t(_crash.out_len))
		if fd_last >= 0 do _ = posix.write(fd_last, raw_data(_crash.out_buf[:]), c.size_t(_crash.out_len))
	}

	n := 0
	if fault_pc != nil {
		_crash.frames[n] = fault_pc
		n += 1
	}
	if fault_lr != nil && fault_lr != fault_pc {
		_crash.frames[n] = fault_lr
		n += 1
	}
	scratch: [CRASH_MAX_FRAMES]rawptr
	captured := int(backtrace(raw_data(scratch[:]), CRASH_MAX_FRAMES))
	HANDLER_FRAMES :: 4
	first := min(HANDLER_FRAMES, captured)
	for i in first ..< captured {
		if n >= CRASH_MAX_FRAMES do break
		f := scratch[i]
		if f == fault_pc || f == fault_lr do continue
		_crash.frames[n] = f
		n += 1
	}
	if n <= 0 {
		msg := "  <unavailable; see 'at:' above>\n"
		if fd >= 0 do _ = posix.write(fd, raw_data(msg), c.size_t(len(msg)))
		if fd_last >= 0 do _ = posix.write(fd_last, raw_data(msg), c.size_t(len(msg)))
		return
	}
	if fd >= 0 do backtrace_symbols_fd(raw_data(_crash.frames[:]), c.int(n), c.int(fd))
	if fd_last >= 0 do backtrace_symbols_fd(raw_data(_crash.frames[:]), c.int(n), c.int(fd_last))
}
