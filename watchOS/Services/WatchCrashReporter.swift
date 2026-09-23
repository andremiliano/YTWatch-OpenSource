import Foundation
import Darwin

/// Captures the actual cause of a crash into the diagnostics log.
///
/// The breadcrumb only says which activity was running ("playing X"). The log shows the app
/// dying 1–3s after playback starts with no error recorded and memory at ~15MB, so it is a
/// fault, not a memory kill — but nothing so far names it. An uncaught Objective-C exception
/// or a fatal signal is the likely shape, and both can be recorded before the process goes.
///
/// Handlers write with `write(2)` to a file descriptor opened up front: no allocation, no
/// Swift runtime work on the failing path, and nothing buffered that could be lost.
enum WatchCrashReporter {
    nonisolated(unsafe) private static var logFD: Int32 = -1

    static func install(logPath: String) {
        logPath.withCString { path in
            logFD = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }
        guard logFD >= 0 else { return }

        // Must be fully qualified: a C function pointer can't capture context, and an
        // unqualified call to a sibling static implicitly captures the metatype.
        NSSetUncaughtExceptionHandler { exception in
            WatchCrashReporter.writeLine("== CRASH uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "no reason")")
            for frame in exception.callStackSymbols.prefix(24) {
                WatchCrashReporter.writeLine("   \(frame)")
            }
        }

        // SIGTRAP covers Swift's own traps (force unwrap of nil, index out of range,
        // arithmetic overflow) — the most likely candidates for an instant death.
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { received in
                WatchCrashReporter.writeLine("== CRASH signal \(received)")
                WatchCrashReporter.writeBacktrace()
                // Restore the default handler and re-raise, so the system still records
                // the crash normally rather than us swallowing it.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    fileprivate static func writeLine(_ text: String) {
        guard logFD >= 0 else { return }
        var bytes = Array(text.utf8)
        bytes.append(0x0A)
        _ = bytes.withUnsafeBufferPointer { write(logFD, $0.baseAddress, $0.count) }
        fsync(logFD)
    }

    /// `backtrace_symbols_fd` is the one backtrace call designed to run in a signal
    /// handler: it writes straight to the descriptor without allocating.
    fileprivate static func writeBacktrace() {
        guard logFD >= 0 else { return }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 32)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, logFD)
        fsync(logFD)
    }
}
