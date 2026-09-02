import Foundation

/// Pure, dependency-free playback queue logic (no AVFoundation / WatchKit).
///
/// This owns the index math that used to live inline in `WatchPlayer` and was the
/// source of the playback crashes (empty ranges, out-of-bounds indices, shuffle
/// getting "stuck"). Keeping it here — pure and deterministic — means it can be
/// unit-tested exhaustively (see PlaybackCoreTests) so the Watch never crashes on
/// an edge case again.
///
/// `order` holds indices into the *current playlist's* track array. `position` is
/// where we are within `order`. All operations are total: they never trap, never
/// index out of bounds, and clamp/validate every input.
public struct PlaybackQueue: Equatable, Sendable {
    public private(set) var order: [Int] = []
    public private(set) var position: Int = 0
    public private(set) var isShuffled: Bool = false

    public init() {}

    /// True when there is nothing to play.
    public var isEmpty: Bool { order.isEmpty }

    /// The track index currently pointed at, or nil if the queue is empty/invalid.
    public var currentIndex: Int? {
        guard position >= 0, position < order.count else { return nil }
        return order[position]
    }

    /// Build the queue from the indices that actually have a playable file.
    /// `start` is the desired starting track index; if it isn't available we fall
    /// back to the first available one. Deterministic given `rng`.
    public mutating func build(
        availableIndices: [Int],
        startAt start: Int,
        shuffled: Bool,
        using rng: inout some RandomNumberGenerator
    ) {
        isShuffled = shuffled
        // Defensive: unique + sorted, drop anything negative.
        let avail = Array(Set(availableIndices.filter { $0 >= 0 })).sorted()
        guard !avail.isEmpty else { order = []; position = 0; return }

        let startIdx = avail.contains(start) ? start : avail[0]
        if shuffled {
            var rest = avail.filter { $0 != startIdx }
            rest.shuffle(using: &rng)
            order = [startIdx] + rest
            position = 0
        } else {
            order = avail
            position = avail.firstIndex(of: startIdx) ?? 0
        }
    }

    public enum AdvanceResult: Equatable, Sendable {
        case play(Int)   // caller should play this track index
        case endReached  // queue exhausted forward with no repeat
        case atStart     // already at the first track going backward
        case empty       // nothing in the queue
    }

    /// Move forward or backward. On forward-past-end: reshuffle/restart if
    /// `repeatAll`, else report `.endReached` (caller decides: next album / auto-mix / stop).
    public mutating func advance(
        forward: Bool,
        repeatAll: Bool,
        availableIndices: [Int],
        using rng: inout some RandomNumberGenerator
    ) -> AdvanceResult {
        guard !order.isEmpty else { return .empty }

        if forward {
            let next = position + 1
            if next < order.count {
                position = next
            } else if repeatAll {
                let restart: Int
                if isShuffled {
                    let avail = availableIndices.filter { $0 >= 0 }
                    restart = avail.randomElement(using: &rng) ?? order[0]
                } else {
                    restart = order.first ?? 0
                }
                build(availableIndices: availableIndices, startAt: restart, shuffled: isShuffled, using: &rng)
                guard !order.isEmpty else { return .empty }
            } else {
                return .endReached
            }
        } else {
            let prev = position - 1
            if prev >= 0 {
                position = prev
            } else if repeatAll {
                position = order.count - 1
            } else {
                return .atStart
            }
        }

        guard let idx = currentIndex else { return .endReached }
        return .play(idx)
    }

    /// Remove a track from *Up Next* only (never the current or already-played items).
    public mutating func remove(trackIndex: Int) {
        guard let qpos = order.firstIndex(of: trackIndex), qpos > position else { return }
        order.remove(at: qpos)
    }

    /// Move a queued track to play immediately after the current one.
    public mutating func moveToNext(trackIndex: Int) {
        guard let qpos = order.firstIndex(of: trackIndex), qpos > position else { return }
        order.remove(at: qpos)
        let insertAt = min(position + 1, order.count)
        order.insert(trackIndex, at: insertAt)
    }

    /// Upcoming track indices (after the current position), capped at `limit`.
    public func upNext(limit: Int) -> [Int] {
        guard limit > 0, position + 1 < order.count else { return [] }
        return Array(order[(position + 1)...].prefix(limit))
    }
}
