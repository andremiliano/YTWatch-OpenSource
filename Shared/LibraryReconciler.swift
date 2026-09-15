import Foundation

/// Pure rules for keeping the Watch library's "Unsorted" playlist honest.
///
/// "Unsorted" holds audio files found on disk with no playlist entry — they're given
/// their raw videoId as a title because nothing else is known. Two things must hold:
/// a track that has a real entry elsewhere must not *also* sit in Unsorted under its
/// raw id, and raw-id placeholders should be recoverable by asking the phone.
enum LibraryReconciler {
    static let unsortedId = "__unsorted__"

    /// Remove Unsorted entries whose videoId is already claimed by a real playlist, and
    /// drop Unsorted entirely once it's empty. Returns nil when nothing changed.
    static func pruneUnsorted(_ playlists: [Playlist]) -> [Playlist]? {
        guard let uIdx = playlists.firstIndex(where: { $0.id == unsortedId }) else { return nil }

        var claimed = Set<String>()
        for (i, p) in playlists.enumerated() where i != uIdx {
            for t in p.tracks { claimed.insert(t.videoId) }
        }

        var result = playlists
        let before = result[uIdx].tracks.count
        result[uIdx].tracks.removeAll { claimed.contains($0.videoId) }

        if result[uIdx].tracks.isEmpty {
            result.remove(at: uIdx)
            return result
        }
        return result[uIdx].tracks.count == before ? nil : result
    }

    /// videoIds in Unsorted that still carry the raw-id placeholder title — the ones
    /// whose real metadata should be requested from the phone.
    static func placeholderIds(in playlists: [Playlist]) -> [String] {
        guard let unsorted = playlists.first(where: { $0.id == unsortedId }) else { return [] }
        return unsorted.tracks.filter { $0.title == $0.videoId }.map(\.videoId)
    }
}
