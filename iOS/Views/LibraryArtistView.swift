import SwiftUI

// MARK: - Artists list (Library → Artists)

struct LibraryArtistsList: View {
    let artists: [ArtistGroup]

    var body: some View {
        ForEach(artists) { artist in
            NavigationLink(destination: LibraryArtistView(artist: artist)) {
                LibraryArtistRow(artist: artist)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct LibraryArtistRow: View {
    let artist: ArtistGroup
    @ObservedObject private var downloader = AudioDownloader.shared

    var body: some View {
        let downloaded = artist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
        HStack(spacing: 12) {
            ThumbnailView(url: artist.tracks.first?.thumbnailURL, size: 48, cornerRadius: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(artist.tracks.count) \(artist.tracks.count == 1 ? "song" : "songs")"
                     + (downloaded > 0 ? " · \(downloaded) downloaded" : ""))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appFaint)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - One artist: every song you have, their albums, and their full YouTube page

struct LibraryArtistView: View {
    let artist: ArtistGroup

    /// Albums you have at least one song from, in first-seen order.
    private var albums: [Playlist] {
        var seen = Set<String>()
        return artist.tracks.compactMap { t in
            guard let id = t.albumId, seen.insert(id).inserted else { return nil }
            return Playlist(id: id, title: t.album ?? "Album", thumbnailURL: t.thumbnailURL, tracks: [])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("\(artist.tracks.count) \(artist.tracks.count == 1 ? "song" : "songs") in your library")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appFaint)
                    Spacer()
                    DownloadAllButton(tracks: artist.tracks)
                }

                if let channelId = artist.artistId {
                    NavigationLink(destination: ArtistView(channelId: channelId, artistName: artist.name)) {
                        HStack {
                            Image(systemName: "square.stack.fill")
                            Text("All albums & singles")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Albums").sectionHeader()
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(albums) { album in
                                    NavigationLink(destination: PlaylistDetailView(playlist: album)) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ThumbnailView(url: album.thumbnailURL, size: 120, cornerRadius: 10)
                                            Text(album.title)
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)
                                                .frame(width: 120, alignment: .leading)
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Songs").sectionHeader()
                    LazyVStack(spacing: 1) {
                        ForEach(artist.tracks) { track in
                            TrackRow(track: track, playlistId: "library", playlistTitle: "Downloads")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Color.appBg.ignoresSafeArea())
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}
