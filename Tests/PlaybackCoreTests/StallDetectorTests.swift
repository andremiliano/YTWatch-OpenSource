import XCTest
@testable import PlaybackCore

final class StallDetectorTests: XCTestCase {

    // MARK: - Normal playback

    func testProgressingNeverStalls() {
        var d = StallDetector()
        var t = 0.0
        for _ in 0..<400 {
            t += 0.5
            let outcome = d.tick(time: t, metadataDuration: 300, assetDuration: nil)
            XCTAssertEqual(outcome, .progressing)
        }
    }

    func testNaNTimeIsNotReady() {
        var d = StallDetector()
        XCTAssertEqual(d.tick(time: .nan, metadataDuration: 200, assetDuration: nil), .notReady)
    }

    func testFirstSampleUnderOneSecondNeverCountsAsStall() {
        // t <= 1.0 is excluded from the stall comparison entirely (track just started).
        var d = StallDetector()
        _ = d.tick(time: 0.5, metadataDuration: 200, assetDuration: nil)
        let outcome = d.tick(time: 0.5, metadataDuration: 200, assetDuration: nil)
        XCTAssertEqual(outcome, .progressing)
    }

    // MARK: - Regression: system pause must not be misread as a stall (bug #1)

    func testResetAfterPauseDoesNotCountResumedSampleAsStall() {
        var d = StallDetector()
        XCTAssertEqual(d.tick(time: 10.0, metadataDuration: 200, assetDuration: nil), .progressing)

        // Simulate WatchPlayer's `player.rate <= 0` branch: one or more polls
        // where the player is paused by the system, each calling reset().
        d.reset()
        d.reset()

        // Time is frozen during the pause, so the first resumed sample reports
        // the same value as before the pause. Before the fix this compared
        // against the stale pre-pause timestamp and counted as a stall tick.
        let resumed = d.tick(time: 10.0, metadataDuration: 200, assetDuration: nil)
        XCTAssertEqual(resumed, .progressing, "a resumed sample after a system pause must establish a fresh baseline, not stall-tick")
    }

    func testRepeatedPauseResumeCyclesNeverAccumulateStallTicks() {
        // Regression for "shuffle plays one song then stops": many short pause/resume
        // cycles in a row (Bluetooth flap, throttling) must never reach the stall threshold.
        var d = StallDetector()
        var t = 10.0
        for _ in 0..<50 {
            XCTAssertEqual(d.tick(time: t, metadataDuration: 200, assetDuration: nil), .progressing)
            d.reset() // simulated pause
            let outcome = d.tick(time: t, metadataDuration: 200, assetDuration: nil) // resume, frozen time
            XCTAssertEqual(outcome, .progressing)
            t += 0.5
        }
    }

    // MARK: - Genuine stalls still get caught

    func testGenuineMidTrackStallTriggersAtThresholdTen() {
        var d = StallDetector()
        _ = d.tick(time: 50.0, metadataDuration: 200, assetDuration: nil) // baseline
        var outcome: StallDetector.Outcome = .progressing
        for i in 1...10 {
            outcome = d.tick(time: 50.0, metadataDuration: 200, assetDuration: nil)
            if i < 10 {
                XCTAssertEqual(outcome, .ticking(i))
            }
        }
        XCTAssertEqual(outcome, .stalled)
    }

    func testGenuineNearEndStallTriggersFasterAtThresholdFour() {
        var d = StallDetector()
        let t = 190.0 // 10s from a 200s track — within the 15s near-end window
        _ = d.tick(time: t, metadataDuration: 200, assetDuration: nil) // baseline
        var outcome: StallDetector.Outcome = .progressing
        for i in 1...4 {
            outcome = d.tick(time: t, metadataDuration: 200, assetDuration: nil)
            if i < 4 {
                XCTAssertEqual(outcome, .ticking(i))
            }
        }
        XCTAssertEqual(outcome, .stalled)
    }

    func testStallTicksResetAfterStalling() {
        var d = StallDetector()
        _ = d.tick(time: 50.0, metadataDuration: 200, assetDuration: nil)
        for _ in 1...10 { _ = d.tick(time: 50.0, metadataDuration: 200, assetDuration: nil) }
        XCTAssertEqual(d.stallTicks, 0, "ticks must reset once .stalled fires so a fresh track doesn't start pre-tripped")
    }

    // MARK: - Regression: wrong/short metadata duration must not trigger early (bug #2)

    func testShortMetadataDurationDoesNotTriggerAggressiveThresholdWhenAssetDurationIsLonger() {
        // Metadata claims the track is 55s (so t=50 looks "near end"), but the real
        // container is 200s. Before the fix this used the 4-tick near-end threshold
        // and skipped on an ordinary mid-track hiccup; it must use the 10-tick one.
        var d = StallDetector()
        _ = d.tick(time: 50.0, metadataDuration: 55, assetDuration: 200)
        for i in 1...3 {
            let outcome = d.tick(time: 50.0, metadataDuration: 55, assetDuration: 200)
            XCTAssertEqual(outcome, .ticking(i), "must not have hit the near-end threshold yet")
        }
        // Still not stalled at tick 4 (would be .stalled here under the bug)
        XCTAssertEqual(d.tick(time: 50.0, metadataDuration: 55, assetDuration: 200), .ticking(4))
    }

    func testNilAssetDurationFallsBackToMetadataDuration() {
        var d = StallDetector()
        _ = d.tick(time: 190.0, metadataDuration: 200, assetDuration: nil)
        var outcome: StallDetector.Outcome = .progressing
        for i in 1...4 {
            outcome = d.tick(time: 190.0, metadataDuration: 200, assetDuration: nil)
            if i < 4 { XCTAssertEqual(outcome, .ticking(i)) }
        }
        XCTAssertEqual(outcome, .stalled, "near-end threshold should still apply using metadata duration alone")
    }

    func testNaNAssetDurationIsIgnored() {
        var d = StallDetector()
        _ = d.tick(time: 50.0, metadataDuration: 200, assetDuration: .nan)
        for _ in 1...9 {
            _ = d.tick(time: 50.0, metadataDuration: 200, assetDuration: .nan)
        }
        // 10th real stall tick (11th call overall) — mid-track threshold, unaffected by the NaN.
        XCTAssertEqual(d.tick(time: 50.0, metadataDuration: 200, assetDuration: .nan), .stalled)
    }

    // MARK: - Fuzz: random interleavings of progress/pause/stall never crash or misbehave

    func testFuzzNeverCrashesAndStallTicksStayBounded() {
        var rng = SeededRNG(seed: 7)
        for trial in 0..<500 {
            var d = StallDetector()
            var t = 0.0
            var lastOutcome: StallDetector.Outcome = .progressing
            for _ in 0..<200 {
                let action = Int.random(in: 0..<3, using: &rng)
                switch action {
                case 0: // normal progress
                    t += Double.random(in: 0.3...2.0, using: &rng)
                case 1: // pause (system-driven)
                    d.reset()
                default:
                    break // stall: time doesn't move
                }
                let metadataDuration = Double.random(in: 0...300, using: &rng)
                let assetDuration: Double? = Bool.random(using: &rng) ? Double.random(in: 0...300, using: &rng) : nil
                lastOutcome = d.tick(time: t, metadataDuration: metadataDuration, assetDuration: assetDuration)

                XCTAssertGreaterThanOrEqual(d.stallTicks, 0, "trial \(trial): stallTicks must never go negative")
                XCTAssertLessThanOrEqual(d.stallTicks, 10, "trial \(trial): stallTicks must never exceed the largest threshold")
                if lastOutcome == .stalled {
                    XCTAssertEqual(d.stallTicks, 0, "trial \(trial): ticks must reset immediately after stalling")
                }
            }
        }
    }
}
