import Foundation

/// Recognises a player parked at the end of its item while playback is still intended.
///
/// Auto-advance normally runs off AVPlayerItemDidPlayToEndTime. When that signal doesn't
/// arrive (build 53 lost it by setting `actionAtItemEnd = .none`, and playback then stopped
/// at the end of every track until skipped by hand) nothing else catches it quickly: the
/// stall detector ignores a stopped player by design, so only the 8s watchdog was left.
/// This gives a 0.5s check that doesn't depend on the notification at all.
enum EndOfItemDetector {
    /// How close to the end still counts as "at the end".
    static let endTolerance: Double = 0.35

    /// - Parameters:
    ///   - time: `player.currentTime().seconds`
    ///   - itemDuration: `playerItem?.duration.seconds` — the *container's* duration.
    ///     Metadata duration is deliberately not accepted here: it can under-report the
    ///     real length, which would cut tracks short.
    ///   - rate: `player.rate` — a player parked at the end has stopped.
    ///   - intendsToPlay: the app's own intent, so user pauses never look like an ending.
    static func isParkedAtEnd(time: Double, itemDuration: Double?, rate: Float, intendsToPlay: Bool) -> Bool {
        guard intendsToPlay, rate == 0 else { return false }
        guard !time.isNaN, time > 1 else { return false }
        guard let d = itemDuration, !d.isNaN, d > 0 else { return false }
        return time >= d - endTolerance
    }
}
