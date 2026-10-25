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

    enum Sort: String, CaseIterable, Identifiable {
        case recent = "Recent", downloaded = "Most downloaded", name = "Name"
        var id: String { rawValue }
    }

    /// `recent` is videoIds, most recently played first. An artist ranks by its most
    /// recent song; artists never played follow, by name. `downloaded` ranks by how many
    /// of the artist's songs `isDownloaded`, ties by name.
    static func sorted(_ groups: [ArtistGroup], by sort: Sort,
                       recent: [String], isDownloaded: (String) -> Bool) -> [ArtistGroup] {
        func byName(_ a: ArtistGroup, _ b: ArtistGroup) -> Bool {
            a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        switch sort {
        case .name:
            return groups.sorted(by: byName)
        case .downloaded:
            let counts = Dictionary(uniqueKeysWithValues: groups.map { g in
                (g.id, g.tracks.filter { isDownloaded($0.videoId) }.count)
            })
            return groups.sorted { a, b in
                counts[a.id]! != counts[b.id]! ? counts[a.id]! > counts[b.id]! : byName(a, b)
            }
        case .recent:
            var rank: [String: Int] = [:]
            for (i, id) in recent.enumerated() where rank[id] == nil { rank[id] = i }
            let best = Dictionary(uniqueKeysWithValues: groups.map { g in
                (g.id, g.tracks.compactMap { rank[$0.videoId] }.min() ?? Int.max)
            })
            return groups.sorted { a, b in
                best[a.id]! != best[b.id]! ? best[a.id]! < best[b.id]! : byName(a, b)
            }
        }
    }

    /// Case- and accent-insensitive name match; an empty query keeps everything.
    static func filter(_ groups: [ArtistGroup], query: String) -> [ArtistGroup] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return groups }
        return groups.filter { $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
