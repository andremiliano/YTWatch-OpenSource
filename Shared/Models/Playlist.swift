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
}
