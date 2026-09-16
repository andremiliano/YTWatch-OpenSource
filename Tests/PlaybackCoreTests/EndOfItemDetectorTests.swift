import XCTest
@testable import PlaybackCore

final class EndOfItemDetectorTests: XCTestCase {

    private func parked(time: Double, duration: Double?, rate: Float = 0, playing: Bool = true) -> Bool {
        EndOfItemDetector.isParkedAtEnd(time: time, itemDuration: duration, rate: rate, intendsToPlay: playing)
    }

    // The build-53 regression: track reaches its end, player stops, no end notification,
    // and playback sat there until skipped by hand.
    func testStoppedExactlyAtTheEndIsDetected() {
        XCTAssertTrue(parked(time: 180, duration: 180))
    }

    func testStoppedJustShortOfTheEndIsDetected() {
        XCTAssertTrue(parked(time: 179.8, duration: 180), "players park a hair before the reported duration")
    }

    func testStillPlayingIsNotAnEnding() {
        XCTAssertFalse(parked(time: 180, duration: 180, rate: 1))
    }

    func testUserPauseAtTheEndIsNotAnEnding() {
        XCTAssertFalse(parked(time: 180, duration: 180, playing: false))
    }

    func testPauseMidTrackIsNotAnEnding() {
        XCTAssertFalse(parked(time: 90, duration: 180))
    }

    // Padded containers report a duration longer than the audio. Those stall with rate > 0
    // and belong to StallDetector; this must not fire early and cut them short.
    func testStoppedWellBeforeTheEndIsNotAnEnding() {
        XCTAssertFalse(parked(time: 120, duration: 180))
    }

    func testUnknownOrInvalidDurationNeverFires() {
        XCTAssertFalse(parked(time: 180, duration: nil))
        XCTAssertFalse(parked(time: 180, duration: .nan))
        XCTAssertFalse(parked(time: 180, duration: 0))
    }

    func testFreshlyLoadedItemNeverFires() {
        // A just-swapped item sits at 0 with rate 0 while it loads.
        XCTAssertFalse(parked(time: 0, duration: 180))
        XCTAssertFalse(parked(time: 0.5, duration: 180))
        XCTAssertFalse(parked(time: .nan, duration: 180))
    }

    func testVeryShortTrackStillDetectedOncePastTheOneSecondFloor() {
        XCTAssertFalse(parked(time: 1, duration: 1), "1s guard excludes the load window")
        XCTAssertTrue(parked(time: 4, duration: 4))
    }

    func testToleranceBoundary() {
        let d = 200.0
        XCTAssertTrue(parked(time: d - EndOfItemDetector.endTolerance, duration: d))
        XCTAssertFalse(parked(time: d - EndOfItemDetector.endTolerance - 0.01, duration: d))
    }

    func testFuzzNeverFiresDuringNormalPlayback() {
        var rng = SeededRNG(seed: 4242)
        for _ in 0..<2000 {
            let duration = Double.random(in: 30...600, using: &rng)
            let time = Double.random(in: 0...(duration - 1), using: &rng)
            // rate > 0 anywhere in the track, or stopped anywhere before the tail
            XCTAssertFalse(parked(time: time, duration: duration, rate: 1))
            if time < duration - EndOfItemDetector.endTolerance {
                XCTAssertFalse(parked(time: time, duration: duration))
            }
        }
    }
}
