import Foundation

/// All songs you have, grouped by artist. Shared by the phone Library and the Watch.
struct ArtistGroup: Identifiable, Equatable {
    let id: String          // lowercased name, so "ARTIST" and "Artist" merge
    let name: String
    let artistId: String?   // YouTube channel (UC…), when any track knows it
    let tracks: [Track]
}

enum ArtistIndex {
    /// Collabs arrive as "A, B" (the parser joins artist runs with ", "), so each
    /// track is listed under every artist on it.
    /// ponytail: a name that itself contains ", " (e.g. "Tyler, The Creator") splits in two;
    /// group on artist ids instead if that bites.
    static func names(in artist: String) -> [String] {
        artist.components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "Unknown" }
    }

    /// Tracks dedupe by videoId (first occurrence wins) and keep their input order
    /// within an artist; artists sort by name.
    static func group(_ tracks: [Track]) -> [ArtistGroup] {
        var order: [String] = []
        var displayName: [String: String] = [:]
        var ids: [String: String] = [:]
        var byArtist: [String: [Track]] = [:]
        var seen = Set<String>()

        for track in tracks where seen.insert(track.videoId).inserted {
            for (i, name) in names(in: track.artist).enumerated() {
                let key = name.lowercased()
                if byArtist[key] == nil { order.append(key); displayName[key] = name }
                byArtist[key, default: []].append(track)
                // Parsers set artistId from the first artist run only.
                if i == 0, ids[key] == nil, let id = track.artistId { ids[key] = id }
            }
        }
        return order
            .map { ArtistGroup(id: $0, name: displayName[$0]!, artistId: ids[$0], tracks: byArtist[$0]!) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
