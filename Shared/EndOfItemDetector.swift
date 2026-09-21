import Foundation

/// Recognises a player parked at the end of its item while playback is still intended.
///
/// Auto-advance normally runs off AVPlayerItemDidPlayToEndTime. When that signal doesn't
/// arrive (build 53 lost it by setting `actionAtItemEnd = .none`, and playback then stopped
/// at the end of every track until skipped by hand) nothing else catches it quickly: the
/// stall detector ignores a stopped player by design, so only the 8s watchdog was left.
/// This gives a ~1s check that doesn't depend on the notification at all.
///
/// Stateful so a single reading can't act on its own: `time` and `itemDuration` are read
/// from a live player and can disagree for a moment during an item swap (a stale clock
/// against an already-resolved shorter duration reads as "ended"). Requiring consecutive
/// agreeing samples removes that race, matching the sibling detectors in this module.
struct EndOfItemDetector: Equatable {
    /// How close to the end still counts as "at the end".
    static let endTolerance: Double = 0.35
    /// Consecutive confirming samples required before reporting an ending.
    static let confirmationsRequired = 2

    private(set) var confirmations = 0

    /// Call when a new item is installed.
    mutating func reset() {
        confirmations = 0
    }

    /// - Parameters:
    ///   - time: `player.currentTime().seconds`
    ///   - itemDuration: duration of the item the clock was read from — pass nil when the
    ///     player's current item isn't the one being tracked, so a swap can't be misread.
    ///     The *container's* duration: metadata duration can under-report and would cut
    ///     tracks short.
    ///   - rate: `player.rate` — a player parked at the end has stopped.
    ///   - intendsToPlay: the app's own intent, so user pauses never look like an ending.
    /// - Returns: true once enough consecutive samples agree the item has ended.
    mutating func tick(time: Double, itemDuration: Double?, rate: Float, intendsToPlay: Bool) -> Bool {
        guard Self.looksParked(time: time, itemDuration: itemDuration, rate: rate, intendsToPlay: intendsToPlay) else {
            confirmations = 0
            return false
        }
        confirmations += 1
        if confirmations >= Self.confirmationsRequired {
            confirmations = 0
            return true
        }
        return false
    }

    /// The single-sample rule, without the confirmation requirement.
    static func looksParked(time: Double, itemDuration: Double?, rate: Float, intendsToPlay: Bool) -> Bool {
        guard intendsToPlay, rate == 0 else { return false }
        guard !time.isNaN, time > 1 else { return false }
        guard let d = itemDuration, !d.isNaN, d > 0 else { return false }
        return time >= d - endTolerance
    }
}
