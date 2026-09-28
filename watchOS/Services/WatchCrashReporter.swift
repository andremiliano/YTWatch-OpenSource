import Foundation
import Darwin

/// Captures the actual cause of a crash, so it can be reported on the next launch.
///
/// Writes to its own file, `crash.log`, which nothing else ever rewrites. The earlier
/// version shared diagnostics.log, whose trimming replaces the file with an atomic write —
/// leaving this reporter's descriptor pointing at a deleted file, so every crash it
/// recorded was lost. A non-empty crash.log at launch means the previous run crashed and
/// says how.
///
/// The signal path only calls write(2), backtrace(3), backtrace_symbols_fd(3), signal(3)
/// and raise(3), using buffers allocated at install time. Allocating inside a signal
/// handler can deadlock on the malloc lock (for example when the crash is itself heap
/// corruption), which turns a crash into a hang and records nothing.
enum WatchCrashReporter {
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var frames: UnsafeMutablePointer<UnsafeMutableRawPointer?>?
    nonisolated(unsafe) private static var digits: UnsafeMutablePointer<UInt8>?
    private static let frameCapacity: Int32 = 48
    private static let digitCapacity = 16

    static var crashLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash.log")
    }

    /// Call first in App.init(), before anything that can fail.
    static func install() {
        fd = crashLogURL.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
        guard fd >= 0 else { return }
        frames = .allocate(capacity: Int(frameCapacity))
        digits = .allocate(capacity: digitCapacity)

        // Runs in a normal context, so formatting here is safe.
        NSSetUncaughtExceptionHandler { exception in
            WatchCrashReporter.recordException(exception)
        }

        // SIGTRAP covers Swift's own traps (nil unwrap, index out of range, overflow).
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP] {
            signal(sig) { received in WatchCrashReporter.handleSignal(received) }
        }
    }

    /// The previous run's crash record, or nil if it ended cleanly. Clears the file by
    /// truncating it in place — never replacing it — so the open descriptor stays valid.
    static func takePreviousCrash() -> String? {
        guard let data = try? Data(contentsOf: crashLogURL), !data.isEmpty else { return nil }
        if fd >= 0 { ftruncate(fd, 0) }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Failing path

    fileprivate static func recordException(_ exception: NSException) {
        guard fd >= 0 else { return }
        var text = "== CRASH uncaught exception: \(exception.name.rawValue): \(exception.reason ?? "no reason")\n"
        for frame in exception.callStackSymbols.prefix(30) {
            text += "   \(frame)\n"
        }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { _ = write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
    }

    fileprivate static func handleSignal(_ sig: Int32) {
        if fd >= 0 {
            writeStatic("== CRASH signal ")
            writeNumber(sig)
            writeStatic("\n")
            if let frames {
                let count = backtrace(frames, frameCapacity)
                backtrace_symbols_fd(frames, count, fd)
            }
            fsync(fd)
        }
        // Hand back to the default action so the system still records the crash.
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static func writeStatic(_ text: StaticString) {
        _ = write(fd, text.utf8Start, text.utf8CodeUnitCount)
    }

    /// Integer to ASCII into the preallocated buffer — no String, no allocation.
    private static func writeNumber(_ value: Int32) {
        guard let digits else { return }
        var remaining = value < 0 ? -Int(value) : Int(value)
        var position = digitCapacity
        repeat {
            position -= 1
            digits[position] = UInt8(48 + remaining % 10)
            remaining /= 10
        } while remaining > 0 && position > 0
        _ = write(fd, digits + position, digitCapacity - position)
    }
}
