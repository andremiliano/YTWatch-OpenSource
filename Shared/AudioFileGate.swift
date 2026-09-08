import Foundation

/// Single source of truth for "is this audio file big enough to trust."
/// Used by WatchFileReceiver (queue building, launch validation, write
/// confirmation, sync-verify inventory) and WatchPlayer (pre-flight before
/// handing a file to AVPlayer) so the four call sites can't drift apart —
/// they previously used three different magic numbers (20_000 / 100_000)
/// with inconsistent boundary semantics (`>` vs `<`) across sites.
enum AudioFileGate {
    static let minValidBytes = 20_000

    static func isValid(sizeBytes: Int) -> Bool {
        sizeBytes > minValidBytes
    }

    /// Filters a raw directory listing down to ids backed by a large-enough
    /// file. Pure — no disk access — so the filtering rule is testable
    /// independent of FileManager/enumerator behavior.
    static func filterValid(_ entries: [(id: String, sizeBytes: Int)]) -> Set<String> {
        var result = Set<String>()
        for entry in entries where isValid(sizeBytes: entry.sizeBytes) {
            result.insert(entry.id)
        }
        return result
    }
}
