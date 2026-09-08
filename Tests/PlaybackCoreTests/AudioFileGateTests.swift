import XCTest
@testable import PlaybackCore

final class AudioFileGateTests: XCTestCase {

    func testFileBelowThresholdIsInvalid() {
        XCTAssertFalse(AudioFileGate.isValid(sizeBytes: 0))
        XCTAssertFalse(AudioFileGate.isValid(sizeBytes: 1))
        XCTAssertFalse(AudioFileGate.isValid(sizeBytes: AudioFileGate.minValidBytes - 1))
    }

    func testFileAtExactThresholdIsInvalid() {
        // Boundary is exclusive (`>`), matching WatchPlayer.playTrack's original gate.
        XCTAssertFalse(AudioFileGate.isValid(sizeBytes: AudioFileGate.minValidBytes))
    }

    func testFileAboveThresholdIsValid() {
        XCTAssertTrue(AudioFileGate.isValid(sizeBytes: AudioFileGate.minValidBytes + 1))
        XCTAssertTrue(AudioFileGate.isValid(sizeBytes: 4_000_000))
    }

    func testNegativeSizeIsInvalid() {
        // Defensive: FileManager attribute lookups fall back to 0 on failure in
        // production, but the gate itself should never accept a bogus negative.
        XCTAssertFalse(AudioFileGate.isValid(sizeBytes: -1))
    }

    // MARK: - Regression: partial/truncated files must never enter the play queue (bug #3)

    func testFilterValidExcludesTruncatedFiles() {
        let entries: [(id: String, sizeBytes: Int)] = [
            ("complete1", 4_000_000),
            ("partial_transfer", 12_000),   // interrupted WCSession transfer
            ("complete2", 3_500_000),
            ("empty_placeholder", 0),
            ("complete3", AudioFileGate.minValidBytes + 1),
        ]
        let result = AudioFileGate.filterValid(entries)
        XCTAssertEqual(result, ["complete1", "complete2", "complete3"])
    }

    func testFilterValidEmptyInputReturnsEmptySet() {
        XCTAssertEqual(AudioFileGate.filterValid([]), [])
    }

    func testFilterValidAllInvalidReturnsEmptySet() {
        let entries: [(id: String, sizeBytes: Int)] = [("a", 0), ("b", 100), ("c", 19_999)]
        XCTAssertTrue(AudioFileGate.filterValid(entries).isEmpty)
    }

    func testFilterValidAllValidReturnsAllIds() {
        let entries: [(id: String, sizeBytes: Int)] = [("a", 50_000), ("b", 100_000), ("c", 1_000_000)]
        XCTAssertEqual(AudioFileGate.filterValid(entries), ["a", "b", "c"])
    }

    func testFilterValidDuplicateIdsCollapseToOne() {
        let entries: [(id: String, sizeBytes: Int)] = [("a", 50_000), ("a", 60_000)]
        XCTAssertEqual(AudioFileGate.filterValid(entries), ["a"])
    }
}
