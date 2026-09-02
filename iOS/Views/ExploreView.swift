import SwiftUI

// MARK: - Store

@MainActor
final class ExploreStore: ObservableObject {
    static let shared = ExploreStore()

    @Published var sections: [YTMusicClient.HomeFeedSection] = []
    @Published var newReleases: [Playlist] = []
    @Published var moods: [YTMusicClient.MoodCategory] = []
    @Published var isLoading = false
    @Published var error: String?

    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated, !isLoading else { return }
        isLoading = true
        error = nil

        async let sectionsTask: Void = fetchSections()
        async let releasesTask: Void = fetchReleases()
        async let moodsTask: Void = fetchMoods()
        _ = await (sectionsTask, releasesTask, moodsTask)

        isLoading = false
    }

    private func fetchSections() async {
        sections = (try? await YTMusicClient.shared.fetchExplore()) ?? []
    }

    private func fetchReleases() async {
        newReleases = (try? await YTMusicClient.shared.fetchNewReleases()) ?? []
    }

    private func fetchMoods() async {
        moods = (try? await YTMusicClient.shared.fetchMoodsAndGenres()) ?? []
    }
}

// MARK: - View

struct ExploreView: View {
    @ObservedObject private var store = ExploreStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false
    @State private var radioTrack: Track?
    @State private var albumTarget: Playlist?
    @State private var artistTarget: (id: String, name: String)?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.isLoading && store.sections.isEmpty && store.newReleases.isEmpty {
                    ProgressView().tint(Color.ytRed)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            // New Releases
                            if !store.newReleases.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("New Releases")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        LazyHStack(spacing: 14) {
                                            ForEach(store.newReleases.prefix(20)) { album in
                                                NavigationLink(destination: PlaylistDetailView(playlist: album)) {
                                                    NewReleaseCard(playlist: album)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, 2)
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82),
                                    value: appeared
                                )
                            }

                            // Moods & Genres
                            if !store.moods.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Moods & Genres")
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    MoodGrid(moods: store.moods)
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 12)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82).delay(0.1),
                                    value: appeared
                                )
                            }

                            // Explore sections (trending, top songs, etc.)
                            ForEach(Array(store.sections.filter { !$0.title.localizedCaseInsensitiveContains("music video") }.enumerated()), id: \.element.id) { i, section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title)
                                        .sectionHeader()
                                        .padding(.horizontal, 4)

                                    if !section.playlists.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            LazyHStack(spacing: 12) {
                                                ForEach(section.playlists) { playlist in
                                                    NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                                        ExplorePlaylistCard(playlist: playlist)
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                            .padding(.horizontal, 2)
                                        }
                                    }

                                    if !section.tracks.isEmpty {
                                        ForEach(section.tracks.prefix(8)) { track in
                                            ExploreTrackRow(track: track, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                                artistTarget = (id, name)
                                            }, onNavigateToAlbum: { id, title, thumb in
                                                albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                            })
                                        }
                                    }
                                }
                                .opacity(appeared ? 1 : 0)
                                .offset(y: appeared ? 0 : 10)
                                .animation(
                                    .spring(response: 0.45, dampingFraction: 0.82)
                                        .delay(0.12 + Double(i) * 0.04),
                                    value: appeared
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Explore")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if store.isLoading {
                        ProgressView().tint(Color.ytRed)
                    } else {
                        Button(action: { Task { await store.refresh() } }) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
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
        }
        .preferredColorScheme(.dark)
        .task { await store.refresh() }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.05)) {
                appeared = true
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && store.sections.isEmpty { Task { await store.refresh() } }
        }
    }
}

// MARK: - New Release Card

private struct NewReleaseCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var allDownloaded: Bool {
        !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { downloader.isDownloaded($0.videoId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: playlist.thumbnailURL, size: 150, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.5), radius: 16, y: 6)

                if allDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.ytRed)
                        .background(Circle().fill(Color.black).padding(-2))
                        .offset(x: -6, y: -6)
                }
            }

            Text(playlist.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: 150, alignment: .leading)

            if let subtitle = playlist.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appFaint)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            }
        }
    }
}

// MARK: - Mood Grid

private struct MoodGrid: View {
    let moods: [YTMusicClient.MoodCategory]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(moods.prefix(12)) { mood in
                NavigationLink(destination: MoodPlaylistsView(mood: mood)) {
                    MoodChip(mood: mood)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct MoodChip: View {
    let mood: YTMusicClient.MoodCategory

    private var chipColor: Color {
        if let hex = mood.color { return Color(hex: hex) }
        let hue = Double(abs(mood.title.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.6, brightness: 0.45)
    }

    var body: some View {
        Text(mood.title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                LinearGradient(
                    colors: [chipColor, chipColor.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Mood Playlists

struct MoodPlaylistsView: View {
    let mood: YTMusicClient.MoodCategory
    @State private var playlists: [Playlist] = []
    @State private var isLoading = true

    var body: some View {
        ZStack {
            Color.appBg.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(Color.ytRed)
            } else if playlists.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40, weight: .ultraLight))
                        .foregroundStyle(Color.appGhost)
                    Text("No playlists found")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.appDim)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(playlists) { playlist in
                            NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                PlaylistRow(playlist: playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle(mood.title)
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            playlists = (try? await YTMusicClient.shared.fetchMoodPlaylists(params: mood.params)) ?? []
            isLoading = false
        }
    }
}

// MARK: - Explore Playlist Card

private struct ExplorePlaylistCard: View {
    let playlist: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared

    private var allDownloaded: Bool {
        !playlist.tracks.isEmpty && playlist.tracks.allSatisfy { downloader.isDownloaded($0.videoId) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: playlist.thumbnailURL, size: 130, cornerRadius: 10)

                if allDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.ytRed)
                        .background(Circle().fill(Color.black).padding(-2))
                        .offset(x: -5, y: -5)
                }
            }

            Text(playlist.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .frame(width: 130, alignment: .leading)

            if let subtitle = playlist.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appFaint)
                    .lineLimit(1)
                    .frame(width: 130, alignment: .leading)
            }
        }
    }
}

// MARK: - Explore Track Row

private struct ExploreTrackRow: View {
    let track: Track
    var onStartRadio: ((Track) -> Void)? = nil
    var onNavigateToArtist: ((String, String) -> Void)? = nil
    var onNavigateToAlbum: ((String, String?, String?) -> Void)? = nil
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var isDownloaded: Bool { downloader.isDownloaded(track.videoId) }
    private var isSynced: Bool { sync.syncedTrackIds.contains(track.videoId) }
    private var progress: Double? { downloader.downloadProgress[track.videoId] }

    private var rowContent: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: track.thumbnailURL, size: 44, cornerRadius: 8)

                if isSynced {
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

// MARK: - Color hex init

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255.0
        let g = Double((int >> 8) & 0xFF) / 255.0
        let b = Double(int & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}
