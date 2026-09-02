import SwiftUI

struct LibraryView: View {
    @ObservedObject private var store = LibraryStore.shared
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared
    @ObservedObject private var client = YTMusicClient.shared
    @State private var appeared = false

    private var libraryTitle: String {
        if let name = client.userDisplayName, !name.isEmpty {
            let first = name.components(separatedBy: " ").first ?? name
            return "\(first)'s Library"
        }
        return "Library"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBg.ignoresSafeArea()

                if store.playlists.isEmpty && !store.isLoading {
                    EmptyLibraryView()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            if downloader.totalQueuedCount > 0 {
                                DownloadProgressCard()
                                    .padding(.bottom, 8)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            } else if downloader.hasActiveDownloads {
                                ActiveDownloadBanner()
                                    .padding(.bottom, 8)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if downloader.failedDownloadCount > 0 && downloader.totalQueuedCount == 0 {
                                FailedDownloadsBanner()
                                    .padding(.bottom, 8)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if !sync.transferringTrackIds.isEmpty || sync.pendingSyncCount > 0 || !sync.syncedTrackIds.isEmpty {
                                WatchSyncBanner()
                                    .padding(.bottom, 8)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }

                            if !store.librarySongs.isEmpty {
                                NavigationLink(destination: PlaylistDetailView(playlist: Playlist(
                                    id: "FEmusic_liked_videos",
                                    title: "Library Songs",
                                    thumbnailURL: nil,
                                    tracks: store.librarySongs
                                ))) {
                                    LibrarySongsCard(count: store.librarySongs.count)
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 4)
                            }

                            ForEach(Array(store.playlists.enumerated()), id: \.element.id) { i, playlist in
                                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                                    PlaylistRow(playlist: playlist)
                                        .opacity(appeared ? 1 : 0)
                                        .offset(y: appeared ? 0 : 12)
                                        .animation(
                                            .spring(response: 0.5, dampingFraction: 0.8)
                                            .delay(Double(i) * 0.04),
                                            value: appeared
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 32)
                    }
                }
            }
            .navigationTitle(libraryTitle)
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
        .task { await store.refreshIfStale() } // throttled — explicit refresh via toolbar button
        .onAppear { withAnimation { appeared = true } }
    }
}

struct PlaylistRow: View {
    let playlist: Playlist
    // Only observe the specific sets we need — avoids re-render on unrelated changes
    @ObservedObject private var downloader = AudioDownloader.shared
    @ObservedObject private var sync = WatchSyncManager.shared

    private var trackCountText: String {
        if playlist.tracks.isEmpty, let sub = playlist.subtitle, !sub.isEmpty {
            return sub
        }
        return "\(playlist.trackCount) tracks"
    }

    private var downloadedCount: Int {
        guard !playlist.tracks.isEmpty else { return 0 }
        return playlist.tracks.reduce(0) { $0 + (downloader.downloadedTracks[$1.videoId] != nil ? 1 : 0) }
    }
    private var syncedCount: Int {
        guard !playlist.tracks.isEmpty else { return 0 }
        return playlist.tracks.reduce(0) { $0 + (sync.syncedTrackIds.contains($1.videoId) ? 1 : 0) }
    }
    private var downloadFraction: Double {
        guard playlist.trackCount > 0 else { return 0 }
        return Double(downloadedCount) / Double(playlist.trackCount)
    }

    var body: some View {
        HStack(spacing: 14) {
            ThumbnailView(url: playlist.thumbnailURL, size: 58, cornerRadius: 10)
                .overlay(alignment: .bottomTrailing) {
                    if syncedCount == playlist.trackCount && playlist.trackCount > 0 {
                        Image(systemName: "applewatch")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(3)
                            .background(Color.ytRed)
                            .clipShape(Circle())
                            .offset(x: 3, y: 3)
                    }
                }

            VStack(alignment: .leading, spacing: 5) {
                Text(playlist.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(trackCountText)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.appFaint)

                // Download progress bar
                if downloadedCount > 0 && downloadedCount < playlist.trackCount {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.appGhost).frame(height: 2)
                            Capsule()
                                .fill(Color.ytRed.opacity(0.8))
                                .frame(width: geo.size.width * downloadFraction, height: 2)
                        }
                    }
                    .frame(height: 2)
                } else if downloadedCount == playlist.trackCount && playlist.trackCount > 0 {
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
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
        .padding(.vertical, 2)
    }
}

private struct DownloadProgressCard: View {
    @ObservedObject private var downloader = AudioDownloader.shared

    private var progress: Double {
        guard downloader.totalQueuedCount > 0 else { return 0 }
        return Double(downloader.completedInBatch) / Double(downloader.totalQueuedCount)
    }

    private var etaText: String? {
        guard let secs = downloader.estimatedSecondsRemaining, secs > 0 else { return nil }
        if secs < 60 { return "\(Int(secs))s left" }
        let mins = Int(secs) / 60
        let remaining = Int(secs) % 60
        if mins < 2 { return "\(mins)m \(remaining)s left" }
        return "~\(mins)m left"
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Color.ytRed)
                        .scaleEffect(0.7)
                    Text("Downloading")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text("\(downloader.completedInBatch)/\(downloader.totalQueuedCount)")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.ytRed)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.appGhost).frame(height: 4)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.ytRed.opacity(0.6), Color.ytRed],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, geo.size.width * progress), height: 4)
                        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: progress)
                }
            }
            .frame(height: 4)

            if let eta = etaText {
                HStack {
                    Spacer()
                    Text(eta)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.appFaint)
                }
            }
        }
        .padding(14)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct FailedDownloadsBanner: View {
    @ObservedObject private var downloader = AudioDownloader.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(downloader.failedDownloadCount) download\(downloader.failedDownloadCount == 1 ? "" : "s") failed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Tap to retry them all")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appFaint)
            }

            Spacer()

            Button {
                downloader.retryAllFailed()
            } label: {
                Text("Retry All")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.orange)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
    }
}

private struct ActiveDownloadBanner: View {
    @ObservedObject private var downloader = AudioDownloader.shared

    var body: some View {
        let count = downloader.downloadProgress.filter { $0.value < 1.0 }.count
        HStack(spacing: 10) {
            ProgressView()
                .tint(Color.ytRed)
                .scaleEffect(0.7)
            Text("Downloading \(count) track\(count == 1 ? "" : "s")")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.2), lineWidth: 0.5)
        )
    }
}

private struct WatchSyncBanner: View {
    @ObservedObject private var sync = WatchSyncManager.shared

    private var totalSyncing: Int {
        sync.transferringTrackIds.count + sync.pendingSyncCount
    }

    private var syncedCount: Int {
        sync.syncedTrackIds.count
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if totalSyncing > 0 {
                    ProgressView()
                        .tint(Color.ytRed)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "applewatch.radiowaves.left.and.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.ytRed)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if totalSyncing > 0 {
                        Text("Syncing to Watch")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("\(totalSyncing) remaining · \(syncedCount) synced")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appFaint)
                    } else {
                        Text("\(syncedCount) tracks on Watch")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                if totalSyncing > 0 {
                    Text("Transfers in background")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.appFaint)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }
}

private struct LibrarySongsCard: View {
    let count: Int
    @ObservedObject private var downloader = AudioDownloader.shared

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.3, green: 0.2, blue: 0.7), Color(red: 0.2, green: 0.1, blue: 0.5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 58, height: 58)
                Image(systemName: "music.note.list")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Library Songs")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(count) songs")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appFaint)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appGhost)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.appBorder, lineWidth: 0.5)
        )
    }
}

private struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44, weight: .ultraLight))
                .foregroundStyle(Color.appGhost)
            Text("No Playlists")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.appDim)
            Text("Pull to refresh or check your connection.")
                .font(.system(size: 13))
                .foregroundStyle(Color.appFaint)
                .multilineTextAlignment(.center)
        }
    }
}
