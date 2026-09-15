import XCTest
@testable import PlaybackCore

final class PlaybackWatchdogTests: XCTestCase {

    /// Feed `count` ticks with a frozen clock and return every non-.none action.
    private func frozenTicks(_ w: inout PlaybackWatchdog, count: Int, rate: Float, at time: Double = 42) -> [PlaybackWatchdog.Action] {
        (0..<count).compactMap { _ in
            let a = w.tick(intendsToPlay: true, rate: rate, time: time)
            return a == .none ? nil : a
        }
    }

    func testHealthyPlaybackNeverActs() {
        var w = PlaybackWatchdog()
        var t = 0.0
        for _ in 0..<1000 {
            t += 0.5
            XCTAssertEqual(w.tick(intendsToPlay: true, rate: 1, time: t), .none)
        }
    }

    func testUserPauseNeverActs() {
        var w = PlaybackWatchdog()
        for _ in 0..<500 {
            XCTAssertEqual(w.tick(intendsToPlay: false, rate: 0, time: 10), .none)
        }
    }

    // Regression: an item that fails mid-track leaves rate 0 while we still intend to play.
    // Previously nothing noticed and the UI showed "playing" over silence forever.
    func testStoppedPlayerWhileIntendingToPlayNudgesThenSkips() {
        var w = PlaybackWatchdog()
        let actions = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0)
        XCTAssertEqual(actions, [.nudge, .skip])
    }

    func testNudgeHappensAtThreeSecondsAndOnlyOnce() {
        var w = PlaybackWatchdog()
        for i in 1..<PlaybackWatchdog.nudgeAfterTicks {
            XCTAssertEqual(w.tick(intendsToPlay: true, rate: 0, time: 5), .none, "tick \(i)")
        }
        XCTAssertEqual(w.tick(intendsToPlay: true, rate: 0, time: 5), .nudge)
        XCTAssertEqual(w.tick(intendsToPlay: true, rate: 0, time: 5), .none)
    }

    // An item that never becomes ready sits at 0:00 with rate 1 — the stall detector
    // excludes t <= 1s, so the watchdog must still catch it (without a pointless nudge).
    func testNeverLoadingItemAtRateOneIsSkippedWithoutNudge() {
        var w = PlaybackWatchdog()
        let actions = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 1, at: 0)
        XCTAssertEqual(actions, [.skip])
    }

    func testRecoveryAfterNudgeClearsTheEpisode() {
        var w = PlaybackWatchdog()
        _ = frozenTicks(&w, count: PlaybackWatchdog.nudgeAfterTicks, rate: 0)
        // play() worked: the clock moves again
        XCTAssertEqual(w.tick(intendsToPlay: true, rate: 1, time: 43), .none)
        XCTAssertEqual(w.stuckTicks, 0)
        // a later, separate stall gets its own full grace period and a fresh nudge
        let later = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0, at: 43)
        XCTAssertEqual(later, [.nudge, .skip])
    }

    // Two dead tracks in a row means the problem is systemic (route/session): stop rather
    // than cycling the whole library every 8 seconds.
    func testSecondConsecutiveDeadTrackGivesUp() {
        var w = PlaybackWatchdog()
        XCTAssertEqual(frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0).last, .skip)
        w.trackStarted()
        XCTAssertEqual(frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0).last, .giveUp)
    }

    func testDeadTrackFollowedByGoodTrackDoesNotEscalate() {
        var w = PlaybackWatchdog()
        _ = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0)
        w.trackStarted()
        var t = 0.0
        for _ in 0..<10 { t += 0.5; _ = w.tick(intendsToPlay: true, rate: 1, time: t) }
        w.trackStarted()
        XCTAssertEqual(frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0).last, .skip,
                       "real progress in between must reset escalation")
    }

    func testUserTakingControlResetsEscalation() {
        var w = PlaybackWatchdog()
        _ = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0)
        w.userTookControl()
        XCTAssertEqual(frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks, rate: 0).last, .skip)
    }

    func testBriefStopUnderThresholdIsIgnored() {
        var w = PlaybackWatchdog()
        var t = 10.0
        for _ in 0..<20 {
            // 2s dip (4 ticks), then playback resumes
            for _ in 0..<4 { XCTAssertEqual(w.tick(intendsToPlay: true, rate: 0, time: t), .none) }
            for _ in 0..<4 { t += 0.5; XCTAssertEqual(w.tick(intendsToPlay: true, rate: 1, time: t), .none) }
        }
    }

    func testSeekingBackwardCountsAsActivity() {
        var w = PlaybackWatchdog()
        _ = w.tick(intendsToPlay: true, rate: 1, time: 120)
        for _ in 0..<5 { _ = w.tick(intendsToPlay: true, rate: 0, time: 120) }
        XCTAssertEqual(w.tick(intendsToPlay: true, rate: 1, time: 3), .none)
        XCTAssertEqual(w.stuckTicks, 0)
    }

    func testPausingMidEpisodeClearsIt() {
        var w = PlaybackWatchdog()
        _ = frozenTicks(&w, count: PlaybackWatchdog.skipAfterTicks - 1, rate: 0)
        XCTAssertEqual(w.tick(intendsToPlay: false, rate: 0, time: 42), .none)
        XCTAssertEqual(w.stuckTicks, 0)
    }

    func testNaNTimeCountsAsStuck() {
        var w = PlaybackWatchdog()
        let actions = (0..<PlaybackWatchdog.skipAfterTicks).compactMap { _ -> PlaybackWatchdog.Action? in
            let a = w.tick(intendsToPlay: true, rate: 0, time: .nan)
            return a == .none ? nil : a
        }
        XCTAssertEqual(actions, [.nudge, .skip])
    }

    func testFuzzNeverSkipsHealthyPlayback() {
        var rng = SeededRNG(seed: 99)
        for _ in 0..<300 {
            var w = PlaybackWatchdog()
            var t = 0.0
            for _ in 0..<400 {
                // Always progresses at least a little each tick, with random rate glitches.
                t += Double.random(in: 0.1...0.9, using: &rng)
                let rate: Float = Bool.random(using: &rng) ? 1 : 0
                XCTAssertEqual(w.tick(intendsToPlay: true, rate: rate, time: t), .none)
            }
        }
    }
}
