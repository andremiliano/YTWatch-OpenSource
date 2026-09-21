import Foundation
import WatchConnectivity

/// A rolling on-device log of what the Watch app actually did, and the means to get it off
/// the Watch without the iPhone being present.
///
/// This app has no readable crash logs, and the Watch is used away from the phone, so every
/// previous diagnosis was guesswork. Events are appended here, persisted across launches,
/// and sent to the iPhone with `transferFile` — which queues and delivers whenever the phone
/// is next in range — where they can be shared as a plain text file.
@MainActor
final class WatchDiagnostics: ObservableObject {
    static let shared = WatchDiagnostics()

    /// Kept small: this lives on a memory-tight device and is only a recent history.
    private static let maxEntries = 600

    @Published private(set) var lastExportSummary: String?

    private var entries: [String] = []
    /// Append handle, so each event reaches disk as it happens. Batching lost the last
    /// entries before a crash — which are the only ones that explain the crash.
    private var handle: FileHandle?
    private var lastExportAt: Date?
    private let fm = FileManager.default

    private var logURL: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("diagnostics.log")
    }

    private init() {
        entries = (try? String(contentsOf: logURL, encoding: .utf8))?
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .suffix(Self.maxEntries)
            .map { $0 } ?? []
        // Rewrite the trimmed history once, then append from here on.
        rewriteFile()
    }

    // MARK: - Recording

    func log(_ message: String) {
        let line = "\(Self.formatter.string(from: Date())) \(message)"
        entries.append(line)
        print("[Diag] \(message)")

        // Straight to disk. Appending one short line is cheap, and it means the event
        // immediately before a crash or a jetsam kill is always on record.
        if let handle, let data = (line + "\n").data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }

        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
            rewriteFile()
        }
    }

    /// Make sure everything buffered by the system is on disk (backgrounding, export).
    func flush() {
        try? handle?.synchronize()
    }

    private func rewriteFile() {
        handle?.closeFile()
        handle = nil
        let text = entries.isEmpty ? "" : entries.joined(separator: "\n") + "\n"
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        handle = try? FileHandle(forWritingTo: logURL)
        try? handle?.seekToEnd()
    }

    // MARK: - Export

    /// Full report: environment header, crash history, then the event log.
    func report() -> String {
        var lines: [String] = []
        lines.append("YTWatch Watch diagnostics")
        lines.append("Watch app version: \(AppVersion.display)")
        lines.append("Exported: \(Self.formatter.string(from: Date()))")
        lines.append("Memory now: \(Self.memoryNote)")

        let receiver = WatchFileReceiver.shared
        // Distinguish audio files from playlist rows: a track that appears in two playlists
        // was being counted twice, which read as more tracks on the watch than there were
        // files (547 rows vs 510 files) and looked like a sync fault that wasn't one.
        let uniqueIds = Set(receiver.availablePlaylists.flatMap { $0.tracks.map(\.videoId) })
        lines.append("Playlists: \(receiver.availablePlaylists.count)")
        lines.append("Audio files on watch: \(receiver.availableTrackIds()?.count ?? -1)")
        lines.append("Unique tracks in playlists: \(uniqueIds.count)")
        lines.append("Playlist rows (duplicates counted): \(receiver.availablePlaylists.reduce(0) { $0 + $1.tracks.count })")
        lines.append(String(format: "Audio storage: %.0f MB", receiver.usedMB))
        lines.append(String(format: "Free space: %.0f MB", receiver.freeDeviceStorageMB))

        if let crash = CrashBreadcrumb.summary {
            lines.append("Last unexpected stop: \(crash)")
        } else {
            lines.append("Last unexpected stop: none recorded")
        }
        lines.append("Unexpected stops recorded: \(CrashBreadcrumb.uncleanCount)")
        lines.append("")
        lines.append("--- events (oldest first, \(entries.count)) ---")
        lines.append(contentsOf: entries)
        return lines.joined(separator: "\n")
    }

    /// Write the report and hand it to WatchConnectivity. The transfer is queued by the
    /// system, so this works with the iPhone switched off or miles away — it arrives when
    /// the two are next together.
    @discardableResult
    func sendToPhone(reason: String) -> Bool {
        // Repeated taps queued a separate file transfer each time (the first export showed
        // three). One is enough; tell the user it already went.
        if let last = lastExportAt, Date().timeIntervalSince(last) < 10 {
            lastExportSummary = "Already sent — check iPhone"
            return true
        }
        lastExportAt = Date()
        log("diagnostics export requested (\(reason))")
        flush()

        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ytwatch-diagnostics.txt")
        guard (try? report().write(to: url, atomically: true, encoding: .utf8)) != nil else {
            lastExportSummary = "Could not write report"
            return false
        }
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else {
            lastExportSummary = "Saved on Watch — will send when paired"
            return false
        }
        WCSession.default.transferFile(url, metadata: [
            WatchMessageKey.type.rawValue: WatchMessageType.diagnostics.rawValue,
            "watchVersion": AppVersion.display
        ])
        lastExportSummary = "Sent \(entries.count) events to iPhone"
        return true
    }

    /// Memory the app is charged for. A watchOS app killed for exceeding its limit leaves
    /// no crash report and no error — the log simply stops. Recording the footprint at
    /// each track start is the way to tell that apart from a code fault: a steady climb
    /// before the log ends means the app was killed for memory.
    static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Double(info.phys_footprint) / 1_048_576
    }

    /// e.g. "mem 41MB"
    static var memoryNote: String {
        guard let mb = memoryFootprintMB() else { return "mem ?" }
        return String(format: "mem %.0fMB", mb)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd HH:mm:ss"
        return f
    }()
}

/// Breadcrumb helper for the watch layer: returns the marker to whatever is genuinely still
/// in flight once a piece of work finishes, rather than leaving the finished activity set
/// (which would later be reported as the cause of an unrelated crash).
@MainActor
enum WatchBreadcrumb {
    static func settled() {
        if WatchPlayer.shared.isPlaying, let track = WatchPlayer.shared.currentTrack {
            CrashBreadcrumb.mark(.startingTrack(track.title))
        } else if WatchFileReceiver.shared.receivingCount > 0 {
            CrashBreadcrumb.mark(.receivingSync)
        } else {
            CrashBreadcrumb.mark(.idle)
        }
    }
}
