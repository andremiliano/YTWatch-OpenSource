import SwiftUI

/// Every artist with songs on the Watch, across all synced playlists.
struct ArtistListView: View {
    let artists: [ArtistGroup]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(artists) { artist in
                    NavigationLink(destination: TrackListView(playlist: Playlist(
                        id: "__artist__\(artist.id)", title: artist.name, thumbnailURL: nil, tracks: artist.tracks
                    ))) {
                        WatchArtistRow(artist: artist)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle("Artists")
    }
}

private struct WatchArtistRow: View {
    let artist: ArtistGroup

    private var thumb: UIImage? {
        artist.tracks.lazy.compactMap { WatchThumbnailCache.shared.image(for: $0.videoId) }.first
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.15).overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(Color(white: 0.35))
                    )
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(artist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(artist.tracks.count) \(artist.tracks.count == 1 ? "song" : "songs")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.38))
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
