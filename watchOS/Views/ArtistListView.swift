import SwiftUI

/// Every artist with songs on the Watch, across all synced playlists.
struct ArtistListView: View {
    let artists: [ArtistGroup]
    @ObservedObject private var receiver = WatchFileReceiver.shared
    @ObservedObject private var player = WatchPlayer.shared
    @AppStorage("artistSort") private var sort: ArtistIndex.Sort = .recent
    @State private var query = ""

    private var shown: [ArtistGroup] {
        let onDisk = receiver.cachedOrFreshTrackIds()
        let sorted = ArtistIndex.sorted(artists, by: sort,
                                        recent: player.recentlyPlayed.map(\.trackVideoId),
                                        isDownloaded: { onDisk.contains($0) })
        return ArtistIndex.filter(sorted, query: query)
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                TextField("Search artists", text: $query)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(white: 0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                // One button cycles the sort: three segments don't fit a Watch row.
                Button {
                    let all = ArtistIndex.Sort.allCases
                    sort = all[(all.firstIndex(of: sort)! + 1) % all.count]
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Sort: \(sort.rawValue)")
                            .font(.system(size: 11, weight: .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color.ytRed)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)

                ForEach(shown) { artist in
                    NavigationLink(destination: TrackListView(playlist: Playlist(
                        id: "__artist__\(artist.id)", title: artist.name, thumbnailURL: nil, tracks: artist.tracks
                    ))) {
                        WatchArtistRow(artist: artist)
                    }
                    .buttonStyle(.plain)
                }

                if shown.isEmpty {
                    Text("No artists match")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(white: 0.4))
                        .padding(.top, 8)
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
