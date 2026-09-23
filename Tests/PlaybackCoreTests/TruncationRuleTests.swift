import XCTest
@testable import PlaybackCore

/// Mirrors WatchFileReceiver.isTruncated. That rule deletes audio and asks for a re-download,
/// so its boundaries matter: too strict and good downloads are destroyed, too loose and the
/// part-downloaded files that cut songs short survive.
private func isTruncated(actualSeconds: Double, expectedSeconds: Int) -> Bool {
    guard expectedSeconds > 30 else { return false }
    let expected = Double(expectedSeconds)
    return actualSeconds < expected * 0.75 && expected - actualSeconds > 30
}

final class TruncationRuleTests: XCTestCase {

    // The two real cases from the diagnostics log.
    func testRealTruncatedFilesAreCaught() {
        XCTAssertTrue(isTruncated(actualSeconds: 19, expectedSeconds: 237), "19s of a 237s track")
        XCTAssertTrue(isTruncated(actualSeconds: 126, expectedSeconds: 262), "126s of a 262s track")
    }

    // Tracks that played to the end in that same log must never be touched.
    func testCompleteFilesAreKept() {
        XCTAssertFalse(isTruncated(actualSeconds: 232, expectedSeconds: 227))
        XCTAssertFalse(isTruncated(actualSeconds: 181, expectedSeconds: 179))
        XCTAssertFalse(isTruncated(actualSeconds: 206, expectedSeconds: 201))
        XCTAssertFalse(isTruncated(actualSeconds: 235, expectedSeconds: 211))
    }

    func testOrdinaryMetadataInaccuracyIsTolerated() {
        // A few seconds out either way is normal and must not delete anything.
        for expected in [120, 180, 240, 300] {
            for delta in [-10.0, -5.0, -1.0, 0.0, 1.0, 5.0, 10.0, 25.0] {
                XCTAssertFalse(isTruncated(actualSeconds: Double(expected) - delta, expectedSeconds: expected),
                               "\(expected)s track \(delta)s short must be kept")
            }
        }
    }

    func testBothConditionsAreRequired() {
        // A quarter short but only 25s short (short track) — kept.
        XCTAssertFalse(isTruncated(actualSeconds: 75, expectedSeconds: 100))
        // More than 30s short but only 10% short (long track) — kept.
        XCTAssertFalse(isTruncated(actualSeconds: 560, expectedSeconds: 620))
        // Both: deleted.
        XCTAssertTrue(isTruncated(actualSeconds: 400, expectedSeconds: 620))
    }

    func testUnknownOrVeryShortExpectedDurationIsNeverJudged() {
        // durationSeconds == 0 means "unknown" for legacy downloads — never delete on that.
        XCTAssertFalse(isTruncated(actualSeconds: 5, expectedSeconds: 0))
        XCTAssertFalse(isTruncated(actualSeconds: 1, expectedSeconds: 30))
        XCTAssertFalse(isTruncated(actualSeconds: 0.5, expectedSeconds: 20))
    }

    func testBoundary() {
        // Exactly 75% and exactly 30s short are both kept; just past both is caught.
        XCTAssertFalse(isTruncated(actualSeconds: 150, expectedSeconds: 200), "exactly 75%")
        XCTAssertFalse(isTruncated(actualSeconds: 170, expectedSeconds: 200), "exactly 30s short")
        XCTAssertTrue(isTruncated(actualSeconds: 149, expectedSeconds: 200))
    }

    func testFuzzNeverFlagsAFileThatIsAtLeastThreeQuartersComplete() {
        var rng = SeededRNG(seed: 31337)
        for _ in 0..<5000 {
            let expected = Int.random(in: 31...900, using: &rng)
            let actual = Double(expected) * Double.random(in: 0.75...1.2, using: &rng)
            XCTAssertFalse(isTruncated(actualSeconds: actual, expectedSeconds: expected),
                           "\(actual)s of \(expected)s must be kept")
        }
    }
}
