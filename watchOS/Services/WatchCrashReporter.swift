import Foundation

/// Records uncaught Objective-C exceptions, so one can be reported on the next launch.
///
/// Deliberately does NOT install signal handlers. watchOS refuses them: calling signal(3)
/// or sigaction(2) for a fatal signal makes libsystem_c trap the app on the spot, with
/// "sigaction on fatal signals is not supported" in the crash report. Builds 58–61
/// installed them at launch — so the reporter added to diagnose crashes was itself the
/// cause of the app closing on every launch (60 of 60 system crash reports, all that one
/// trap). Do not re-add them.
///
/// Swift traps (nil unwrap, index out of range, invalid conversion) raise SIGTRAP and so
/// can't be captured in-process on watchOS. They don't need to be: the system writes a
/// full crash report for them, which syncs to the paired iPhone and can be pulled with
/// `xcrun devicectl device info files --domain-type systemCrashLogs`.
enum WatchCrashReporter {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static var crashLogURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("crash.log")
    }

    /// Call early in App.init(). Opens the log and registers the exception handler only.
    static func install() {
        fd = crashLogURL.path.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
        guard fd >= 0 else { return }
        // Not a signal handler: Foundation calls this in a normal context for an
        // Objective-C exception nobody caught, so formatting and allocating are fine.
        NSSetUncaughtExceptionHandler { exception in
            WatchCrashReporter.recordException(exception)
        }
    }

    /// The previous run's exception record, or nil. Clears the file by truncating it in
    /// place — never replacing it — so the open descriptor stays valid.
    static func takePreviousCrash() -> String? {
        guard let data = try? Data(contentsOf: crashLogURL), !data.isEmpty else { return nil }
        if fd >= 0 { ftruncate(fd, 0) }
        return String(decoding: data, as: UTF8.self)
    }

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
}
