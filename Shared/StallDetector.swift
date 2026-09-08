import Foundation

/// Pure decision logic for watchOS playback stall detection, extracted from
/// WatchPlayer's 0.5s polling timer so the exact rules can be unit/fuzz tested
/// without AVFoundation. One instance's lifetime matches one loaded track.
struct StallDetector: Equatable {
    enum Outcome: Equatable {
        case notReady     // no usable time sample this tick (NaN)
        case progressing  // time advanced since the last sample
        case ticking(Int) // no progress; tick count so far, still below threshold
        case stalled      // hit threshold — caller should treat the track as finished
    }

    private(set) var stallTicks: Int = 0
    private(set) var lastObservedTime: Double = -1

    /// Call whenever the player isn't actively advancing (system pause, route
    /// change, buffering — rate <= 0). Resets to the "no baseline yet" sentinel
    /// so the tick right after resume isn't compared against a stale
    /// pre-pause timestamp and misread as a stall.
    mutating func reset() {
        stallTicks = 0
        lastObservedTime = -1
    }

    /// Feed one poll sample.
    /// - Parameters:
    ///   - t: `player.currentTime().seconds`
    ///   - metadataDuration: synced/API track duration; may be 0 if unknown
    ///   - assetDuration: `playerItem?.duration.seconds`; may be nil/NaN if unknown
    ///
    /// The larger of `metadataDuration`/`assetDuration` is used for the
    /// near-end check, so a synced duration that under-reports the real
    /// length can't drop mid-track playback into the aggressive threshold.
    mutating func tick(time t: Double, metadataDuration: Double, assetDuration: Double?) -> Outcome {
        guard !t.isNaN else { return .notReady }

        guard t > 1.0, lastObservedTime >= 0, abs(t - lastObservedTime) < 0.05 else {
            stallTicks = 0
            lastObservedTime = t
            return .progressing
        }

        stallTicks += 1

        let effectiveDuration = [metadataDuration, assetDuration]
            .compactMap { $0 }
            .filter { !$0.isNaN && $0 > 0 }
            .max() ?? metadataDuration
        let isNearEnd = effectiveDuration > 0 && (effectiveDuration - t) < 15.0
        let threshold = isNearEnd ? 4 : 10

        if stallTicks >= threshold {
            stallTicks = 0
            return .stalled
        }
        return .ticking(stallTicks)
    }
}
