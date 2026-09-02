import SwiftUI

struct SearchView: View {
    @State private var query = ""
    @State private var results = YTMusicClient.SearchResults()
    @State private var suggestions: [String] = []
    @State private var isSearching = false
    @State private var hasSearched = false
    @State private var error: String?
    @State private var resultsAppeared = false
    @State private var suggestionsTask: Task<Void, Never>?
    @State private var radioTrack: Track?
    @State private var albumTarget: Playlist?
    @State private var artistTarget: (id: String, name: String)?
    @State private var recentSearches: [String] = SearchHistory.load()
    @FocusState private var focused: Bool

    private var showSuggestions: Bool {
        focused && !query.trimmingCharacters(in: .whitespaces).isEmpty && !hasSearched && !suggestions.isEmpty
    }

    /// Show recent searches when the field is focused but empty
    private var showRecents: Bool {
        focused && query.trimmingCharacters(in: .whitespaces).isEmpty && !recentSearches.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search bar
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(focused ? Color.ytRed : Color.appFaint)

                            TextField("Songs, albums, artists…", text: $query)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .tint(Color.ytRed)
                                .focused($focused)
                                .submitLabel(.search)
                                .onSubmit { runSearch() }
                                .onChange(of: query) { _, newValue in
                                    let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                                    if trimmed.isEmpty {
                                        results = YTMusicClient.SearchResults()
                                        suggestions = []
                                        hasSearched = false
                                        return
                                    }
                                    // Editing after a search returns to suggestion mode
                                    if hasSearched { hasSearched = false }
                                    fetchSuggestions(for: newValue)
                                }

                            if !query.isEmpty {
                                Button {
                                    query = ""
                                    results = YTMusicClient.SearchResults()
                                    suggestions = []
                                    hasSearched = false
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(Color.appFaint)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.appSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(focused ? Color.ytRed.opacity(0.5) : Color.appBorder, lineWidth: 0.5)
                        )
                        .animation(.easeInOut(duration: 0.15), value: focused)

                        if focused {
                            Button("Cancel") {
                                query = ""
                                focused = false
                                results = YTMusicClient.SearchResults()
                                suggestions = []
                                hasSearched = false
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.ytRed)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: focused)

                    if isSearching {
                        Spacer()
                        ProgressView().tint(Color.ytRed)
                        Spacer()
                    } else if showRecents {
                        RecentSearchesList(
                            recents: recentSearches,
                            onTap: { term in query = term; runSearch() },
                            onClear: { recentSearches = []; SearchHistory.clear() }
                        )
                    } else if showSuggestions {
                        SuggestionsList(suggestions: suggestions) { suggestion in
                            query = suggestion
                            runSearch()
                        }
                    } else if !hasSearched {
                        SearchIdleView()
                    } else if results.songs.isEmpty && results.albums.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40, weight: .ultraLight))
                                .foregroundStyle(Color.appGhost)
                            Text("No results for \"\(query)\"")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                if !results.albums.isEmpty {
                                    SearchSection(title: "Albums & Singles") {
                                        ForEach(Array(results.albums.enumerated()), id: \.element.id) { i, album in
                                            NavigationLink(destination: PlaylistDetailView(playlist: album)) {
                                                SearchAlbumRow(album: album)
                                            }
                                            .buttonStyle(.plain)
                                            .opacity(resultsAppeared ? 1 : 0)
                                            .offset(y: resultsAppeared ? 0 : 10)
                                            .animation(
                                                .spring(response: 0.4, dampingFraction: 0.82).delay(Double(i) * 0.04),
                                                value: resultsAppeared
                                            )
                                        }
                                    }
                                }

                                if !results.songs.isEmpty {
                                    SearchSection(title: "Songs") {
                                        ForEach(Array(results.songs.enumerated()), id: \.element.id) { i, song in
                                            SearchSongRow(track: song, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                                artistTarget = (id, name)
                                            }, onNavigateToAlbum: { id, title, thumb in
                                                albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                            })
                                                .opacity(resultsAppeared ? 1 : 0)
                                                .offset(y: resultsAppeared ? 0 : 10)
                                                .animation(
                                                    .spring(response: 0.4, dampingFraction: 0.82)
                                                        .delay(0.05 + Double(i) * 0.03),
                                                    value: resultsAppeared
                                                )
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 8)
                            .padding(.bottom, 40)
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
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Color.appBg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
        .preferredColorScheme(.dark)
    }

    private func runSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        focused = false
        isSearching = true
        hasSearched = true
        resultsAppeared = false
        suggestions = []
        suggestionsTask?.cancel()
        recentSearches = SearchHistory.add(trimmed)
        Task {
            do {
                results = try await YTMusicClient.shared.search(query: trimmed)
            } catch {
                self.error = error.localizedDescription
            }
            isSearching = false
            withAnimation { resultsAppeared = true }
        }
    }

    private func fetchSuggestions(for text: String) {
        suggestionsTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { suggestions = []; return }
        suggestionsTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let result = (try? await YTMusicClient.shared.fetchSearchSuggestions(query: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { suggestions = result }
        }
    }
}

// MARK: - Search History

enum SearchHistory {
    private static let key = "recentSearches"
    private static let maxItems = 12

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @discardableResult
    static func add(_ term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return load() }
        var items = load().filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        items.insert(t, at: 0)
        if items.count > maxItems { items = Array(items.prefix(maxItems)) }
        UserDefaults.standard.set(items, forKey: key)
        return items
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Recent Searches List

private struct RecentSearchesList: View {
    let recents: [String]
    let onTap: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Text("RECENT")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.appFaint)
                    Spacer()
                    Button("Clear", action: onClear)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.ytRed)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

                ForEach(Array(recents.enumerated()), id: \.offset) { i, term in
                    Button { onTap(term) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appFaint)
                                .frame(width: 20)
                            Text(term)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.appGhost)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)

                    if i < recents.count - 1 {
                        Divider().background(Color.appBorder).padding(.leading, 54)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Suggestions List

private struct SuggestionsList: View {
    let suggestions: [String]
    let onTap: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { i, suggestion in
                    Button { onTap(suggestion) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.appFaint)
                                .frame(width: 20)

                            Text(suggestion)
                                .font(.system(size: 15))
                                .foregroundStyle(.white)
                                .lineLimit(1)

                            Spacer()

                            Image(systemName: "arrow.up.left")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.appGhost)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 13)
                    }
                    .buttonStyle(.plain)

                    if i < suggestions.count - 1 {
                        Divider()
                            .background(Color.appBorder)
                            .padding(.leading, 54)
                    }
                }
            }
            .padding(.top, 4)
        }
    }
}

// MARK: - Search Idle View

private struct SearchIdleView: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(Color.appGhost)

                Text("Search YouTube Music")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.appDim)

                Text("Find songs and albums to download directly to your Apple Watch.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appFaint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
        }
    }
}

// MARK: - Section wrapper

private struct SearchSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .sectionHeader()
                .padding(.leading, 4)
            VStack(spacing: 2) { content }
        }
    }
}

// MARK: - Album row

private struct SearchAlbumRow: View {
    let album: Playlist
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var downloadedCount: Int {
        guard !album.tracks.isEmpty else { return 0 }
        return album.tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var syncedCount: Int {
        guard !album.tracks.isEmpty else { return 0 }
        return album.tracks.filter { sync.syncedTrackIds.contains($0.videoId) }.count
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                ThumbnailView(url: album.thumbnailURL, size: 56, cornerRadius: 8)

                if syncedCount == album.trackCount && album.trackCount > 0 {
                    Image(systemName: "applewatch")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(2.5)
                        .background(Color.ytRed)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                } else if downloadedCount == album.trackCount && album.trackCount > 0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Color.ytRed)
                        .clipShape(Circle())
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                if let subtitle = album.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                        .lineLimit(1)
                } else {
                    Text("Album")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appFaint)
                }

                if downloadedCount > 0 && downloadedCount < album.trackCount {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.appGhost).frame(height: 2)
                            Capsule()
                                .fill(Color.ytRed.opacity(0.8))
                                .frame(width: geo.size.width * Double(downloadedCount) / Double(max(album.trackCount, 1)), height: 2)
                        }
                    }
                    .frame(height: 2)
                } else if downloadedCount == album.trackCount && album.trackCount > 0 {
                    HStack(spacing: 4) {
                        Circle().fill(Color.ytRed).frame(width: 5, height: 5)
                        Text("Downloaded")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.ytRed.opacity(0.8))
                    }
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }
}

// MARK: - Search song row

private struct SearchSongRow: View {
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
                ThumbnailView(url: track.thumbnailURL, size: 44, cornerRadius: 8)

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
