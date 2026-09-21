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
    private static let flushEvery = 15

    @Published private(set) var lastExportSummary: String?

    private var entries: [String] = []
    private var sinceFlush = 0
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
    }

    // MARK: - Recording

    func log(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        entries.append("\(stamp) \(message)")
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        print("[Diag] \(message)")
        sinceFlush += 1
        if sinceFlush >= Self.flushEvery { flush() }
    }

    /// Persist buffered entries. Called on a cadence, when backgrounding, and before export
    /// — a crash loses at most the last few lines, and the line before the gap is the clue.
    func flush() {
        sinceFlush = 0
        let text = entries.joined(separator: "\n")
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
    }

    // MARK: - Export

    /// Full report: environment header, crash history, then the event log.
    func report() -> String {
        var lines: [String] = []
        lines.append("YTWatch Watch diagnostics")
        lines.append("Watch app version: \(AppVersion.display)")
        lines.append("Exported: \(Self.formatter.string(from: Date()))")

        let receiver = WatchFileReceiver.shared
        lines.append("Playlists: \(receiver.availablePlaylists.count)")
        lines.append("Tracks on watch: \(receiver.availablePlaylists.reduce(0) { $0 + $1.tracks.count })")
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
