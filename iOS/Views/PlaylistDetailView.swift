import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @State private var tracks: [Track] = []
    @State private var isLoadingTracks = false
    @State private var appeared = false
    @State private var showDeleteAllConfirm = false
    @State private var radioTrack: Track?
    @State private var albumTarget: Playlist?
    @State private var artistTarget: (id: String, name: String)?

    private var downloadedCount: Int {
        tracks.filter { downloader.isDownloaded($0.videoId) }.count
    }
    private var allDownloaded: Bool { downloadedCount == tracks.count && !tracks.isEmpty }
    private var allSynced: Bool { tracks.allSatisfy { sync.syncedTrackIds.contains($0.videoId) } }
    // Derived from actual downloader state — survives navigation
    private var isDownloadingAny: Bool {
        tracks.contains { downloader.isDownloading($0.videoId) || downloader.isQueued($0.videoId) }
    }
    private var isSyncingAny: Bool {
        tracks.contains { sync.transferringTrackIds.contains($0.videoId) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.appBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    PlaylistHeroHeader(
                        playlist: playlist,
                        trackCount: tracks.count,
                        downloadedCount: downloadedCount
                    )
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : -8)

                    if isLoadingTracks {
                        ProgressView()
                            .tint(Color.ytRed)
                            .padding(.top, 48)
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                                TrackRow(track: track, playlistId: playlist.id, playlistTitle: playlist.title, onStartRadio: { radioTrack = $0 }, onNavigateToArtist: { id, name in
                                    artistTarget = (id, name)
                                }, onNavigateToAlbum: { id, title, thumb in
                                    albumTarget = Playlist(id: id, title: title ?? "Album", thumbnailURL: thumb, tracks: [])
                                })
                                    .opacity(appeared ? 1 : 0)
                                    .offset(y: appeared ? 0 : 8)
                                    .animation(
                                        .spring(response: 0.45, dampingFraction: 0.82)
                                            .delay(0.1 + Double(i) * 0.025),
                                        value: appeared
                                    )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 120)
                    }
                }
            }

            if !isLoadingTracks {
                FloatingActionBar(
                    tracks: tracks,
                    allSynced: allSynced,
                    isWorking: isDownloadingAny || isSyncingAny,
                    downloadedCount: downloadedCount,
                    onAction: downloadAndSync
                )
                .opacity(appeared ? 1 : 0)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.appBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if downloadedCount > 0 {
                        Button(role: .destructive) {
                            showDeleteAllConfirm = true
                        } label: {
                            Label("Remove All Downloads", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundStyle(Color.appDim)
                }
            }
        }
        .alert("Remove All Downloads?", isPresented: $showDeleteAllConfirm) {
            Button("Remove", role: .destructive) {
                let ids = tracks.map(\.videoId)
                downloader.deleteAllDownloads(for: ids)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete \(downloadedCount) downloaded tracks from this playlist.")
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { appeared = true }
        }
        .task {
            if !playlist.tracks.isEmpty {
                tracks = playlist.tracks
            } else {
                isLoadingTracks = true
                do {
                    tracks = try await YTMusicClient.shared.fetchPlaylistTracks(playlistId: playlist.id)
                } catch {
                    print("[Detail] track load failed for \(playlist.id): \(error)")
                }
                isLoadingTracks = false
            }
        }
    }

    private func downloadAndSync() {
        // Fire-and-forget — AudioDownloader owns the task lifecycle
        downloader.downloadBatch(tracks: tracks, playlistId: playlist.id, playlistTitle: playlist.title)

        // Sync after a short delay to let downloads queue up
        if sync.isAvailable {
            let allTracks = tracks
            var p = playlist
            p.tracks = allTracks
            Task.detached {
                // Wait briefly for downloads to start, then push playlist index
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await MainActor.run {
                    WatchSyncManager.shared.syncPlaylist(p)
                }
            }
        }
    }
}

// MARK: - Hero Header

private struct PlaylistHeroHeader: View {
    let playlist: Playlist
    let trackCount: Int
    let downloadedCount: Int

    @State private var heroImage: UIImage?

    var body: some View {
        ZStack {
            if let img = heroImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 260)
                    .clipped()
                    .blur(radius: 60)
                    .overlay(Color.appBg.opacity(0.55))
                    .overlay(
                        LinearGradient(
                            colors: [Color.appBg.opacity(0), Color.appBg],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .mask(
                        LinearGradient(
                            colors: [.black, .black, .black.opacity(0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }

            VStack(spacing: 16) {
                ThumbnailView(url: playlist.thumbnailURL, size: 140, cornerRadius: 16)
                    .shadow(color: .black.opacity(0.7), radius: 32, y: 12)

                VStack(spacing: 6) {
                    Text(playlist.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    HStack(spacing: 12) {
                        if trackCount > 0 {
                            Label("\(trackCount) tracks", systemImage: "music.note")
                        }
                        if downloadedCount > 0 {
                            Text("·")
                            Label("\(downloadedCount) downloaded", systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(Color.ytRed.opacity(0.8))
                        }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appFaint)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .task(id: playlist.thumbnailURL) {
            guard let urlStr = playlist.thumbnailURL, let url = URL(string: urlStr) else { return }
            if let cached = ThumbnailCache.shared.get(urlStr) { heroImage = cached; return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = UIImage(data: data) else { return }
            ThumbnailCache.shared.set(img, for: urlStr)
            withAnimation(.easeIn(duration: 0.4)) { heroImage = img }
        }
    }
}

// MARK: - Floating Action Bar

private struct FloatingActionBar: View {
    let tracks: [Track]
    let allSynced: Bool
    let isWorking: Bool
    let downloadedCount: Int
    let onAction: () -> Void

    @ObservedObject private var sync = WatchSyncManager.shared
    @ObservedObject private var downloader = AudioDownloader.shared

    private var trackCount: Int { tracks.count }

    /// Tracks not downloaded, not downloading, not queued, not errored — truly need first download
    private var notStartedCount: Int {
        tracks.filter { t in
            !downloader.isDownloaded(t.videoId) &&
            !downloader.isDownloading(t.videoId) &&
            !downloader.isQueued(t.videoId) &&
            downloader.downloadErrors[t.videoId] == nil
        }.count
    }

    /// Tracks with errors that can be retried
    private var errorCount: Int {
        tracks.filter { t in
            downloader.downloadErrors[t.videoId] != nil &&
            !downloader.isDownloading(t.videoId) &&
            !downloader.isQueued(t.videoId)
        }.count
    }

    private var label: String {
        if allSynced { return "Synced to Watch" }
        if downloadedCount == trackCount && !sync.isAvailable { return "Downloaded" }
        if isWorking && notStartedCount > 0 { return "Download Remaining (\(notStartedCount))" }
        if isWorking && errorCount > 0 { return "Retry Failed (\(errorCount))" }
        if isWorking { return downloadedCount < trackCount ? "Downloading…" : "Syncing to Watch" }
        if errorCount > 0 { return "Retry Failed (\(errorCount))" }
        return "Download & Sync"
    }

    private var icon: String {
        if allSynced { return "applewatch.radiowaves.left.and.right" }
        if downloadedCount == trackCount && !sync.isAvailable { return "checkmark.circle.fill" }
        return "arrow.down.to.line.circle"
    }

    private var isDone: Bool {
        allSynced || (downloadedCount == trackCount && !sync.isAvailable)
    }

    var body: some View {
        VStack(spacing: 10) {
            if isWorking {
                let progress = Double(downloadedCount) / Double(max(trackCount, 1))
                VStack(spacing: 6) {
                    HStack {
                        HStack(spacing: 6) {
                            ProgressView().tint(Color.ytRed).scaleEffect(0.7)
                            Text(downloadedCount < trackCount ? "Downloading" : "Syncing to Watch")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.appDim)
                        }
                        Spacer()
                        Text("\(downloadedCount) / \(trackCount)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Color.appDim)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.appGhost)
                                .frame(height: 4)
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color.ytRed.opacity(0.7), Color.ytRed],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, geo.size.width * progress), height: 4)
                                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
                        }
                    }
                    .frame(height: 4)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(Color.appSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.appBorder, lineWidth: 0.5)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button(action: onAction) {
                HStack(spacing: 8) {
                    if isWorking && notStartedCount == 0 && errorCount == 0 {
                        ProgressView().tint(.white).scaleEffect(0.75)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 15))
                    }
                    Text(label)
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(isDone ? Color.appDim : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(isDone ? Color.appSurface : Color.ytRed)
                .clipShape(Capsule())
            }
            .disabled(isDone)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            LinearGradient(
                colors: [Color.appBg.opacity(0), Color.appBg, Color.appBg],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Track Row

struct TrackRow: View {
    let track: Track
    var playlistId: String?
    var playlistTitle: String?
    var onStartRadio: ((Track) -> Void)? = nil
    var onNavigateToArtist: ((String, String) -> Void)? = nil
    var onNavigateToAlbum: ((String, String?, String?) -> Void)? = nil
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var progress: Double? { downloader.downloadProgress[track.videoId] }
    private var isDownloaded: Bool { downloader.isDownloaded(track.videoId) }
    private var isDownloading: Bool { downloader.isDownloading(track.videoId) }
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

            TrackDownloadButton(track: track, playlistId: playlistId, playlistTitle: playlistTitle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            if isDownloading {
                Button {
                    downloader.cancelDownload(videoId: track.videoId)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else if !isDownloaded {
                Button {
                    Task { _ = try? await AudioDownloader.shared.download(track: track, playlistId: playlistId, playlistTitle: playlistTitle) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            } else {
                Button(role: .destructive) {
                    downloader.deleteDownload(videoId: track.videoId)
                } label: {
                    Label("Remove Download", systemImage: "trash")
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

struct TrackDownloadButton: View {
    let track: Track
    var playlistId: String?
    var playlistTitle: String?
    @ObservedObject private var downloader = AudioDownloader.shared
    @State private var showError = false

    private var progress: Double? { downloader.downloadProgress[track.videoId] }
    private var isDownloaded: Bool { downloader.isDownloaded(track.videoId) }
    private var isDownloading: Bool { downloader.isDownloading(track.videoId) }
    private var hasError: Bool { downloader.downloadErrors[track.videoId] != nil }

    var body: some View {
        Button {
            if isDownloading {
                downloader.cancelDownload(videoId: track.videoId)
            } else if hasError {
                showError = true
            } else if !isDownloaded {
                Task {
                    do { _ = try await AudioDownloader.shared.download(track: track, playlistId: playlistId, playlistTitle: playlistTitle) } catch {}
                }
            }
        } label: {
            ZStack {
                if isDownloading, let p = progress {
                    ZStack {
                        Circle().stroke(Color.appGhost, lineWidth: 1.5)
                        Circle()
                            .trim(from: 0, to: p)
                            .stroke(Color.ytRed, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.appDim)
                    }
                    .frame(width: 22, height: 22)
                } else if isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.ytRed.opacity(0.7))
                } else if hasError {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.appDim)
                }
            }
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .alert("Download Failed", isPresented: $showError) {
            Button("Retry") {
                downloader.downloadErrors.removeValue(forKey: track.videoId)
                Task {
                    do { _ = try await AudioDownloader.shared.download(track: track, playlistId: playlistId, playlistTitle: playlistTitle) } catch {}
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(downloader.downloadErrors[track.videoId] ?? "Unknown error")
        }
    }
}

// MARK: - Radio View

struct RadioView: View {
    let sourceTrack: Track
    @State private var radioPlaylist: Playlist?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if isLoading {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    VStack(spacing: 16) {
                        ProgressView().tint(Color.ytRed)
                        Text("Building radio from \(sourceTrack.title)…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.appDim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }
            } else if let playlist = radioPlaylist {
                PlaylistDetailView(playlist: playlist)
            } else {
                ZStack {
                    Color.appBg.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36, weight: .ultraLight))
                            .foregroundStyle(Color.appGhost)
                        Text(error ?? "Could not load radio")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Color.appDim)
                    }
                }
            }
        }
        .navigationTitle("Radio")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                radioPlaylist = try await YTMusicClient.shared.fetchRadio(videoId: sourceTrack.videoId)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }
}
