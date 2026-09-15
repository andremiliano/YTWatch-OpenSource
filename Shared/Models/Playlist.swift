import Foundation

struct Playlist: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let thumbnailURL: String?
    var tracks: [Track]

    var trackCount: Int { tracks.count }

    var totalDurationSeconds: Int {
        tracks.reduce(0) { $0 + $1.durationSeconds }
    }

    init(id: String, title: String, subtitle: String? = nil, thumbnailURL: String?, tracks: [Track]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURL = thumbnailURL
        self.tracks = tracks
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, thumbnailURL, tracks
    }

    /// Lossy: a malformed track is dropped instead of failing the whole playlist (and,
    /// through `[Playlist]`, the whole library). See `Playlist.decodeLossy(from:)`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        tracks = (try? c.decodeIfPresent([Lossy<Track>].self, forKey: .tracks))?.compactMap(\.value) ?? []
    }

    /// Decode a saved library, keeping every playlist that can be read. A strict
    /// `[Playlist]` decode discards *everything* when any single element is bad.
    static func decodeLossy(from data: Data) -> [Playlist]? {
        guard let items = try? JSONDecoder().decode([Lossy<Playlist>].self, from: data) else { return nil }
        return items.compactMap(\.value)
    }
}

/// Decodes to `nil` instead of throwing, so one bad element can't sink an array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}
