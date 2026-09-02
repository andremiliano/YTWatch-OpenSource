import SwiftUI

// MARK: - Store

@MainActor
final class ForYouStore: ObservableObject {
    static let shared = ForYouStore()

    @Published var likedSongs: Playlist?
    @Published var recentlyPlayed: [Track] = []
    @Published var sections: [YTMusicClient.HomeFeedSection] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated, !isLoading else { return }
        isLoading = true
        error = nil

        async let likedTask: Void = fetchLiked()
        async let recentTask: Void = fetchRecent()
        async let sectionsTask: Void = fetchSections()
        _ = await (likedTask, recentTask, sectionsTask)

        isLoading = false
    }

    private func fetchLiked() async {
        let tracks = (try? await YTMusicClient.shared.fetchLikedSongs()) ?? []
        likedSongs = Playlist(
            id: "VLSE",
            title: "Liked Songs",
            thumbnailURL: nil,
            tracks: tracks
        )
    }

    private func fetchRecent() async {
        recentlyPlayed = (try? await YTMusicClient.shared.fetchRecentlyPlayed()) ?? []
    }

    private func fetchSections() async {
        do {
            sections = try await YTMusicClient.shared.fetchHomeFeedSectioned()
        } catch {
            if likedSongs == nil { self.error = error.localizedDescription }
        }
    }
}

// MARK: - View

struct ForYouView: View {
    @ObservedObject private var store = ForYouStore.shared
    @ObservedObject private var client = YTMusicClient.shared
    @State private var appeared = false
    @State private var radioTrack: Track?
    @State private var albumTarget: Playlist?
    @State private var artistTarget: (id: String, name: String)?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.isLoading && store.likedSongs == nil && store.sections.isEmpty {
                    ProgressView()
                        .tint(Color.ytRed)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            // Liked Songs card
                            if let liked = store.likedSongs {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Your Music")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    NavigationLink(destination: PlaylistDetailView(playlist: liked)) {
                                        LikedSongsCard(playlist: liked)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                            }

                            // Album/playlist sections first (For You, Listen Again, etc.)
                            ForEach(Array(store.sections.filter { !$0.playlists.isEmpty }.enumerated()), id: \.element.id) { sectionIdx, section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title)
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(spacing: 12) {
                                            ForEach(section.playlists) { playlist in
                                                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                                    PlaylistCard(playlist: playlist)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82)
                                        .delay(0.08 + Double(sectionIdx) * 0.04),
                                    value: appeared
                                )
                            }

                            // Recently Played tracks
                            if !store.recentlyPlayed.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Recently Played")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    ForEach(Array(store.recentlyPlayed.prefix(10).enumerated()), id: \.element.id) { i, track in
                                        ForYouTrackRow(track: track, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                            artistTarget = (id, name)
                                        }, onNavigateToAlbum: { id, title, thumb in
                                            albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                        })
                                            .opacity(appeared ? 1 : 0)
                                            .offset(y: appeared ? 0 : 8)
                                            .animation(
                                                .spring(response: 0.4, dampingFraction: 0.82)
                                                    .delay(0.08 + Double(i) * 0.025),
                                                value: appeared
                                            )
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                            }

                            // Track-only sections after
                            ForEach(Array(store.sections.filter { $0.playlists.isEmpty && !$0.tracks.isEmpty }.enumerated()), id: \.element.id) { sectionIdx, section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title)
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    ForEach(Array(section.tracks.enumerated()), id: \.element.id) { i, track in
                                        ForYouTrackRow(track: track, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                            artistTarget = (id, name)
                                        }, onNavigateToAlbum: { id, title, thumb in
                                            albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                        })
                                            .opacity(appeared ? 1 : 0)
                                            .offset(y: appeared ? 0 : 8)
                                            .animation(
                                                .spring(response: 0.4, dampingFraction: 0.82)
                                                    .delay(0.05 + Double(i) * 0.025),
                                                value: appeared
                                            )
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82)
                                        .delay(0.08 + Double(sectionIdx) * 0.04),
                                    value: appeared
                                )
                            }

                            if store.likedSongs == nil && store.sections.isEmpty && !store.isLoading {
                                EmptyForYouView()
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { radioTrack != nil },
                set: { if !$0 { radioTrack = nil } }
            )) {
                if let track = radioTrack {
                    RadioView(sourceTrack: track)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { albumTarget != nil },
                set: { if !$0 { albumTarget = nil } }
            )) {
                if let album = albumTarget {
                    PlaylistDetailView(playlist: album)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { artistTarget != nil },
                set: { if !$0 { artistTarget = nil } }
            )) {
                if let target = artistTarget {
                    ArtistView(channelId: target.id, artistName: target.name)
                }
            }
            .navigationTitle(forYouTitle)
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView()
                            .tint(Color.ytRed)
                    } else {
                        Button(action: { Task { await store.refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { store.error != nil },
                set: { if !$0 { store.error = nil } }
            )) {
                Button("OK", role: .cancel) { store.error = nil }
            } message: {
                Text(store.error ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .task { await store.refresh() }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
    }

    private var forYouTitle: String {
        if let name = client.userDisplayName, !name.isEmpty {
            let first = name.components(separatedBy: " ").first ?? name
            return "For \(first)"
        }
        return "For You"
    }
}

// MARK: - Liked Songs Card

private struct LikedSongsCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var downloadedCount: Int {
        playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.ytRed, Color.ytRed.opacity(0.6)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 64, height: 64)
                Image(systemName: "heart.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Liked Songs")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                if playlist.tracks.isEmpty {
                    Text("Tap to load")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                } else {
                    Text("\(playlist.tracks.count) songs")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)

                    if downloadedCount > 0 {
                        HStack(spacing: 4) {
                            Circle().fill(Color.ytRed).frame(width: 5, height: 5)
                            Text("\(downloadedCount) downloaded")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Color.ytRed.opacity(0.9))
                        }
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(16)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Playlist Card (horizontal scroll)

private struct PlaylistCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var downloadedCount: Int {
        guard !playlist.tracks.isEmpty else { return 0 }
        return playlist.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var syncedCount: Int {
        guard !playlist.tracks.isEmpty else { return 0 }
        return playlist.tracks.filter { sync.syncedTrackIds.contains($0.videoId) }.count
    }
    private var allDownloaded: Bool {
        downloadedCount == playlist.trackCount && playlist.trackCount > 0
    }
    private var allSynced: Bool {
        syncedCount == playlist.trackCount && playlist.trackCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: playlist.thumbnailURL, size: 140, cornerRadius: 12)

                if allSynced {
                    Image(systemName: "applewatch")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(3)
                        .background(Color.ytRed)
                        .clipShape(Circle())
                        .offset(x: -6, y: -6)
                } else if allDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.ytRed)
                        .background(Circle().fill(Color.black).padding(-2))
                        .offset(x: -6, y: -6)
                }
            }

            Text(playlist.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: 140, alignment: .leading)

            if let subtitle = playlist.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appFaint)
                    .lineLimit(1)
                    .frame(width: 140, alignment: .leading)
            }

            if downloadedCount > 0 && downloadedCount < playlist.trackCount {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.appGhost).frame(height: 2)
                        Capsule()
                            .fill(Color.ytRed.opacity(0.8))
                            .frame(width: geo.size.width * Double(downloadedCount) / Double(max(playlist.trackCount, 1)), height: 2)
                    }
                }
                .frame(width: 140, height: 2)
            } else if allDownloaded {
                HStack(spacing: 4) {
                    Circle().fill(Color.ytRed).frame(width: 4, height: 4)
                    Text(allSynced ? "On Watch" : "Downloaded")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.ytRed.opacity(0.8))
                }
            }
        }
    }
}

// MARK: - Track Row (for ForYou feed)

private struct ForYouTrackRow: View {
    let track: Track
    var onStartRadio: ((Track) -> Void)? = nil
    var onNavigateToArtist: ((String, String) -> Void)? = nil
    var onNavigateToAlbum: ((String, String?, String?) -> Void)? = nil
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var progress: Double? { downloader.downloadProgress[track.videoId] }
    private var isDownloaded: Bool { downloader.isDownloaded(track.videoId) }
    private var isSynced: Bool { sync.syncedTrackIds.contains(track.videoId) }
    private var isTransferring: Bool { sync.transferringTrackIds.contains(track.videoId) }

    private var rowContent: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: track.thumbnailURL, size: 48, cornerRadius: 8)

                if isTransferring {
                    ProgressView().tint(.white).scaleEffect(0.5)
                        .frame(width: 14, height: 14)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                } else if isSynced {
                    Image(systemName: "applewatch")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Color.ytRed)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                } else if isDownloaded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Color.ytRed)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(track.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let artistId = track.artistId, onNavigateToArtist != nil {
                    Button {
                        onNavigateToArtist?(artistId, track.artist)
                    } label: {
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.appFaint)
                            .lineLimit(1)
                            .underline(color: Color.appFaint.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(track.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(track.durationFormatted)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appGhost)

            TrackDownloadButton(track: track)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }

    var body: some View {
        rowContent
            .contentShape(Rectangle())
            .onTapGesture {
                if let albumId = track.albumId {
                    onNavigateToAlbum?(albumId, track.album, track.thumbnailURL)
                }
            }
            .contextMenu {
                if isDownloaded {
                    Button(role: .destructive) {
                        downloader.deleteDownload(videoId: track.videoId)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if progress == nil {
                    Button {
                        Task { _ = try? await AudioDownloader.shared.download(track: track) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
                if onStartRadio != nil {
                    Button { onStartRadio?(track) } label: {
                        Label("Start Radio", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
    }
}

// MARK: - Empty State

private struct EmptyForYouView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.appGhost)
            Text("Nothing here yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appDim)
            Text("Pull to refresh or check your connection.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appFaint)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 80)
    }
}
