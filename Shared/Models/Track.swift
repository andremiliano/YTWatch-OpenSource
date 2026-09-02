import Foundation

struct Track: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let videoId: String
    let title: String
    let artist: String
    let album: String?
    let durationSeconds: Int
    let thumbnailURL: String?
    let artistId: String?
    let albumId: String?

    // Transient — not synced to watch
    var isDownloadedOnPhone: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, videoId, title, artist, album, durationSeconds, thumbnailURL, artistId, albumId
    }

    init(id: String, videoId: String, title: String, artist: String, album: String? = nil, durationSeconds: Int, thumbnailURL: String? = nil, artistId: String? = nil, albumId: String? = nil) {
        self.id = id
        self.videoId = videoId
        self.title = title
        self.artist = artist
        self.album = album
        self.durationSeconds = durationSeconds
        self.thumbnailURL = thumbnailURL
        self.artistId = artistId
        self.albumId = albumId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        videoId = try c.decode(String.self, forKey: .videoId)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decodeIfPresent(String.self, forKey: .album)
        durationSeconds = try c.decode(Int.self, forKey: .durationSeconds)
        thumbnailURL = try c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        artistId = try c.decodeIfPresent(String.self, forKey: .artistId)
        albumId = try c.decodeIfPresent(String.self, forKey: .albumId)
    }

    var durationFormatted: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
