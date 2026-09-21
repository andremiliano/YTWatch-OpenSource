import XCTest
@testable import PlaybackCore

final class EndOfItemDetectorTests: XCTestCase {

    private func looksParked(time: Double, duration: Double?, rate: Float = 0, playing: Bool = true) -> Bool {
        EndOfItemDetector.looksParked(time: time, itemDuration: duration, rate: rate, intendsToPlay: playing)
    }

    /// Feed the same reading repeatedly; returns how many ticks until it reports an ending
    /// (nil if it never does within `limit`).
    private func ticksUntilFire(time: Double, duration: Double?, rate: Float = 0, playing: Bool = true, limit: Int = 10) -> Int? {
        var d = EndOfItemDetector()
        for i in 1...limit {
            if d.tick(time: time, itemDuration: duration, rate: rate, intendsToPlay: playing) { return i }
        }
        return nil
    }

    // MARK: - The rule

    // The build-53 regression: track reaches its end, player stops, no end notification,
    // and playback sat there until skipped by hand.
    func testStoppedAtTheEndIsDetected() {
        XCTAssertEqual(ticksUntilFire(time: 180, duration: 180), EndOfItemDetector.confirmationsRequired)
        XCTAssertEqual(ticksUntilFire(time: 179.8, duration: 180), EndOfItemDetector.confirmationsRequired,
                       "players park a hair before the reported duration")
    }

    func testStillPlayingIsNotAnEnding() {
        XCTAssertNil(ticksUntilFire(time: 180, duration: 180, rate: 1))
    }

    func testUserPauseIsNotAnEnding() {
        XCTAssertNil(ticksUntilFire(time: 180, duration: 180, playing: false))
        XCTAssertNil(ticksUntilFire(time: 90, duration: 180))
    }

    // Padded containers report a duration longer than the audio. Those stall with rate > 0
    // and belong to StallDetector; this must not fire early and cut them short.
    func testStoppedWellBeforeTheEndIsNotAnEnding() {
        XCTAssertNil(ticksUntilFire(time: 120, duration: 180))
    }

    func testUnknownOrInvalidDurationNeverFires() {
        XCTAssertNil(ticksUntilFire(time: 180, duration: nil))
        XCTAssertNil(ticksUntilFire(time: 180, duration: .nan))
        XCTAssertNil(ticksUntilFire(time: 180, duration: 0))
    }

    func testFreshlyLoadedItemNeverFires() {
        XCTAssertNil(ticksUntilFire(time: 0, duration: 180))
        XCTAssertNil(ticksUntilFire(time: 0.5, duration: 180))
        XCTAssertNil(ticksUntilFire(time: .nan, duration: 180))
    }

    func testToleranceBoundary() {
        let d = 200.0
        XCTAssertTrue(looksParked(time: d - EndOfItemDetector.endTolerance, duration: d))
        XCTAssertFalse(looksParked(time: d - EndOfItemDetector.endTolerance - 0.01, duration: d))
    }

    // MARK: - Confirmation (the mid-swap race)

    func testSingleSampleIsNotEnoughToAct() {
        var d = EndOfItemDetector()
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true),
                       "one reading must never advance the track on its own")
    }

    // During an item swap the clock can still read the old item while the duration already
    // belongs to the new one. That transient must not be treated as an ending — which is
    // why the caller passes nil when the item identities don't match.
    func testTransientDisagreementDoesNotFire() {
        var d = EndOfItemDetector()
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true))
        // next tick: swap completed, caller reports "not the same item"
        XCTAssertFalse(d.tick(time: 180, itemDuration: nil, rate: 0, intendsToPlay: true))
        // and the new item plays from the start
        XCTAssertFalse(d.tick(time: 0.2, itemDuration: 200, rate: 1, intendsToPlay: true))
        XCTAssertEqual(d.confirmations, 0)
    }

    func testConfirmationsResetWhenPlaybackResumes() {
        var d = EndOfItemDetector()
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true))
        XCTAssertFalse(d.tick(time: 180.1, itemDuration: 180, rate: 1, intendsToPlay: true))
        XCTAssertEqual(d.confirmations, 0, "a moving player clears the count")
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true),
                       "so the next episode starts from scratch")
    }

    func testResetOnNewTrackClearsPartialConfirmation() {
        var d = EndOfItemDetector()
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true))
        d.reset()
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true),
                       "after reset a single sample must not fire")
    }

    func testFiringResetsSoItDoesNotRepeatEveryTick() {
        var d = EndOfItemDetector()
        for _ in 1..<EndOfItemDetector.confirmationsRequired {
            _ = d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true)
        }
        XCTAssertTrue(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true))
        XCTAssertFalse(d.tick(time: 180, itemDuration: 180, rate: 0, intendsToPlay: true),
                       "must not re-fire on the very next tick")
    }

    func testFuzzNeverFiresDuringNormalPlayback() {
        var rng = SeededRNG(seed: 4242)
        for _ in 0..<2000 {
            var d = EndOfItemDetector()
            let duration = Double.random(in: 30...600, using: &rng)
            let time = Double.random(in: 0...(duration - 1), using: &rng)
            XCTAssertFalse(d.tick(time: time, itemDuration: duration, rate: 1, intendsToPlay: true))
            if time < duration - EndOfItemDetector.endTolerance {
                XCTAssertFalse(d.tick(time: time, itemDuration: duration, rate: 0, intendsToPlay: true))
            }
        }
    }
}
