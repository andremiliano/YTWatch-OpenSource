import XCTest
@testable import PlaybackCore

/// Deterministic RNG so shuffle tests are reproducible.
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

final class PlaybackQueueTests: XCTestCase {

    private func rng(_ seed: UInt64 = 42) -> SeededRNG { SeededRNG(seed: seed) }

    // MARK: - Build

    func testBuildSequential() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2, 3, 4], startAt: 2, shuffled: false, using: &r)
        XCTAssertEqual(q.order, [0, 1, 2, 3, 4])
        XCTAssertEqual(q.position, 2)
        XCTAssertEqual(q.currentIndex, 2)
    }

    func testBuildEmptyIsSafe() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [], startAt: 0, shuffled: false, using: &r)
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.currentIndex)          // must never trap
        XCTAssertEqual(q.upNext(limit: 10), [])
    }

    func testBuildEmptyShuffledIsSafe() {
        // This is the "Shuffle All with no downloaded files" crash case.
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [], startAt: 3, shuffled: true, using: &r)
        XCTAssertTrue(q.isEmpty)
        XCTAssertNil(q.currentIndex)
    }

    func testBuildSingleTrack() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [7], startAt: 7, shuffled: true, using: &r)
        XCTAssertEqual(q.order, [7])
        XCTAssertEqual(q.currentIndex, 7)
    }

    func testBuildStartOutOfRangeFallsBack() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [2, 5, 9], startAt: 100, shuffled: false, using: &r)
        XCTAssertEqual(q.currentIndex, 2)     // falls back to first available
    }

    func testBuildStartNotAvailableFallsBack() {
        // startAt refers to a track whose file is missing (not in availableIndices)
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [1, 3, 5], startAt: 4, shuffled: false, using: &r)
        XCTAssertEqual(q.currentIndex, 1)
    }

    func testBuildDropsNegativeAndDuplicates() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [3, 3, -1, 1, 1, 2], startAt: 2, shuffled: false, using: &r)
        XCTAssertEqual(q.order, [1, 2, 3])
        XCTAssertEqual(q.currentIndex, 2)
    }

    func testShuffleKeepsStartFirstAndContainsAll() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: Array(0..<10), startAt: 5, shuffled: true, using: &r)
        XCTAssertEqual(q.order.first, 5)                 // current stays first
        XCTAssertEqual(Set(q.order), Set(0..<10))         // no track lost or duplicated
        XCTAssertEqual(q.order.count, 10)
    }

    // MARK: - Advance forward

    func testAdvanceForwardStepsThrough() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 0, shuffled: false, using: &r)
        XCTAssertEqual(q.advance(forward: true, repeatAll: false, availableIndices: [0, 1, 2], using: &r), .play(1))
        XCTAssertEqual(q.advance(forward: true, repeatAll: false, availableIndices: [0, 1, 2], using: &r), .play(2))
    }

    func testAdvancePastEndNoRepeatReportsEnd() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1], startAt: 1, shuffled: false, using: &r)  // start at last
        XCTAssertEqual(q.advance(forward: true, repeatAll: false, availableIndices: [0, 1], using: &r), .endReached)
    }

    func testAdvancePastEndWithRepeatAllRestarts() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 2, shuffled: false, using: &r)
        let result = q.advance(forward: true, repeatAll: true, availableIndices: [0, 1, 2], using: &r)
        // Restarts the playlist — plays a valid track, never crashes
        if case .play(let idx) = result {
            XCTAssertTrue([0, 1, 2].contains(idx))
        } else {
            XCTFail("Expected .play on repeat-all restart, got \(result)")
        }
        XCTAssertFalse(q.isEmpty)
    }

    func testRepeatAllShuffledRestartNeverEmptyOrCrash() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: Array(0..<5), startAt: 4, shuffled: true, using: &r)
        // Exhaust and wrap several times — must always yield a playable index.
        for _ in 0..<50 {
            let result = q.advance(forward: true, repeatAll: true, availableIndices: Array(0..<5), using: &r)
            if case .play(let idx) = result {
                XCTAssertTrue((0..<5).contains(idx))
            } else {
                XCTFail("repeat-all should always play, got \(result)")
            }
        }
    }

    func testAdvanceOnEmptyQueueIsEmpty() {
        var q = PlaybackQueue()
        var r = rng()
        XCTAssertEqual(q.advance(forward: true, repeatAll: true, availableIndices: [], using: &r), .empty)
    }

    // MARK: - Advance backward

    func testAdvanceBackward() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 2, shuffled: false, using: &r)
        XCTAssertEqual(q.advance(forward: false, repeatAll: false, availableIndices: [0, 1, 2], using: &r), .play(1))
    }

    func testAdvanceBackwardAtStart() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 0, shuffled: false, using: &r)
        XCTAssertEqual(q.advance(forward: false, repeatAll: false, availableIndices: [0, 1, 2], using: &r), .atStart)
        XCTAssertEqual(q.currentIndex, 0)   // stays put
    }

    // MARK: - Queue editing

    func testRemoveFromUpNext() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2, 3], startAt: 0, shuffled: false, using: &r)
        q.remove(trackIndex: 2)
        XCTAssertEqual(q.order, [0, 1, 3])
        XCTAssertEqual(q.currentIndex, 0)
    }

    func testRemoveCurrentIsNoOp() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 1, shuffled: false, using: &r)
        q.remove(trackIndex: 1)             // current — must not remove
        XCTAssertEqual(q.order, [0, 1, 2])
        XCTAssertEqual(q.currentIndex, 1)
    }

    func testRemoveAlreadyPlayedIsNoOp() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 2, shuffled: false, using: &r)
        q.remove(trackIndex: 0)             // behind current
        XCTAssertEqual(q.order, [0, 1, 2])
    }

    func testRemoveNonexistentIsNoOp() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 0, shuffled: false, using: &r)
        q.remove(trackIndex: 99)
        XCTAssertEqual(q.order, [0, 1, 2])
    }

    func testMoveToNext() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2, 3, 4], startAt: 0, shuffled: false, using: &r)
        q.moveToNext(trackIndex: 4)
        XCTAssertEqual(q.order, [0, 4, 1, 2, 3])
        XCTAssertEqual(q.currentIndex, 0)
        // Next advance should play the moved track
        XCTAssertEqual(q.advance(forward: true, repeatAll: false, availableIndices: [0, 1, 2, 3, 4], using: &r), .play(4))
    }

    func testMoveToNextCurrentIsNoOp() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2], startAt: 1, shuffled: false, using: &r)
        q.moveToNext(trackIndex: 1)
        XCTAssertEqual(q.order, [0, 1, 2])
    }

    // MARK: - Up Next

    func testUpNext() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1, 2, 3, 4], startAt: 1, shuffled: false, using: &r)
        XCTAssertEqual(q.upNext(limit: 10), [2, 3, 4])
        XCTAssertEqual(q.upNext(limit: 2), [2, 3])
        XCTAssertEqual(q.upNext(limit: 0), [])
    }

    func testUpNextAtEnd() {
        var q = PlaybackQueue()
        var r = rng()
        q.build(availableIndices: [0, 1], startAt: 1, shuffled: false, using: &r)
        XCTAssertEqual(q.upNext(limit: 10), [])
    }

    // MARK: - Fuzz: never crash, position always valid

    func testFuzzNeverCrashesAndStaysConsistent() {
        var r = rng(12345)
        for iteration in 0..<2000 {
            var q = PlaybackQueue()
            let count = Int(r.next() % 12)                     // 0...11 tracks
            let avail = (0..<count).filter { _ in r.next() % 2 == 0 } // random subset available
            let start = count > 0 ? Int(r.next() % UInt64(count)) : 0
            let shuffled = r.next() % 2 == 0
            q.build(availableIndices: avail, startAt: start, shuffled: shuffled, using: &r)

            // Random ops
            for _ in 0..<20 {
                let op = r.next() % 4
                switch op {
                case 0:
                    _ = q.advance(forward: true, repeatAll: r.next() % 2 == 0, availableIndices: avail, using: &r)
                case 1:
                    _ = q.advance(forward: false, repeatAll: false, availableIndices: avail, using: &r)
                case 2:
                    q.remove(trackIndex: Int(r.next() % 12))
                default:
                    q.moveToNext(trackIndex: Int(r.next() % 12))
                }
                // Invariant: position is always a valid index into order (or order empty)
                if q.order.isEmpty {
                    XCTAssertNil(q.currentIndex, "iter \(iteration): empty order must yield nil current")
                } else {
                    XCTAssertTrue(q.position >= 0 && q.position < q.order.count,
                                  "iter \(iteration): position \(q.position) out of range for order \(q.order)")
                    XCTAssertEqual(Set(q.order).count, q.order.count,
                                   "iter \(iteration): order has duplicates \(q.order)")
                }
            }
        }
    }
}
