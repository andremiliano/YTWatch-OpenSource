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

    /// Only `videoId` is truly required. Everything else degrades to a usable default,
    /// because a single strict failure here used to fail the decode of the *entire*
    /// saved library — which is how whole libraries turned into raw-videoId entries.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        videoId = try c.decode(String.self, forKey: .videoId)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? videoId
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? videoId
        artist = (try? c.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        album = try? c.decodeIfPresent(String.self, forKey: .album)
        durationSeconds = (try? c.decodeIfPresent(Int.self, forKey: .durationSeconds)) ?? 0
        thumbnailURL = try? c.decodeIfPresent(String.self, forKey: .thumbnailURL)
        artistId = try? c.decodeIfPresent(String.self, forKey: .artistId)
        albumId = try? c.decodeIfPresent(String.self, forKey: .albumId)
    }

    /// Same track with a corrected artist (Track's fields are immutable).
    func withArtist(_ artist: String, artistId: String?) -> Track {
        var t = Track(id: id, videoId: videoId, title: title, artist: artist, album: album,
                      durationSeconds: durationSeconds, thumbnailURL: thumbnailURL,
                      artistId: artistId ?? self.artistId, albumId: albumId)
        t.isDownloadedOnPhone = isDownloadedOnPhone
        return t
    }

    var durationFormatted: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
