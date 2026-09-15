import Foundation

/// Detects playback that has silently stopped while the app still intends to play.
///
/// `StallDetector` only handles a player whose rate is > 0 but whose clock is frozen
/// (padded containers near the end). It deliberately ignores a stopped player so a
/// system pause isn't treated as a stall. That leaves a hole: an item that errors out
/// mid-track, never becomes ready, or is paused behind our back leaves the UI showing
/// "playing" over silence, with nothing ever advancing. This covers that hole.
///
/// Pure and dependency-free so the rules are unit-tested; one 0.5s tick per call.
struct PlaybackWatchdog: Equatable {
    enum Action: Equatable {
        case none
        /// Stuck for a few seconds with the player stopped — try `play()` again.
        case nudge
        /// Still stuck — give up on this track and move to the next.
        case skip
        /// The track we skipped to *also* never played. Something systemic is wrong
        /// (audio route, session), so stop cleanly instead of burning through the
        /// whole library a few seconds at a time.
        case giveUp
    }

    /// 3s at 0.5s ticks.
    static let nudgeAfterTicks = 6
    /// 8s at 0.5s ticks.
    static let skipAfterTicks = 16

    private(set) var stuckTicks = 0
    private(set) var nudged = false
    /// True after a `.skip` until real progress is observed again.
    private(set) var skippedWithoutProgress = false
    private var lastTime: Double = -1

    /// Call when a new track is loaded. Keeps `skippedWithoutProgress`, which is exactly
    /// what lets two consecutive dead tracks escalate to `.giveUp`.
    mutating func trackStarted() {
        stuckTicks = 0
        nudged = false
        lastTime = -1
    }

    /// Call on any explicit user play/pause/skip: the user is steering, so forget history.
    mutating func userTookControl() {
        trackStarted()
        skippedWithoutProgress = false
    }

    /// - Parameters:
    ///   - intendsToPlay: the app's own intent (`isPlaying`). False during user pauses,
    ///     interruptions, and route loss — those are never treated as failures.
    ///   - rate: `player.rate`
    ///   - time: `player.currentTime().seconds`
    mutating func tick(intendsToPlay: Bool, rate: Float, time: Double) -> Action {
        guard intendsToPlay else {
            stuckTicks = 0
            nudged = false
            if !time.isNaN { lastTime = time }
            return .none
        }

        let clockMoved = !time.isNaN && lastTime >= 0 && abs(time - lastTime) > 0.05
        if !time.isNaN { lastTime = time }

        // A moving clock means audio is flowing, whatever `rate` says.
        if clockMoved {
            stuckTicks = 0
            nudged = false
            skippedWithoutProgress = false
            return .none
        }

        stuckTicks += 1

        if stuckTicks >= Self.skipAfterTicks {
            stuckTicks = 0
            nudged = false
            if skippedWithoutProgress {
                skippedWithoutProgress = false
                return .giveUp
            }
            skippedWithoutProgress = true
            return .skip
        }

        if stuckTicks >= Self.nudgeAfterTicks, !nudged, rate == 0 {
            nudged = true
            return .nudge
        }
        return .none
    }
}
