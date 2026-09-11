import SwiftUI
import UIKit

struct PlaylistListView: View {
    @ObservedObject private var receiver = WatchFileReceiver.shared
    @ObservedObject private var player = WatchPlayer.shared
    @State private var isRefreshing = false
    @State private var searchText = ""
    @State private var showSearch = false

    private var filteredPlaylists: [Playlist] {
        let all = receiver.availablePlaylists
        guard !searchText.isEmpty else { return all }
        let q = searchText.lowercased()
        return all.filter { playlist in
            playlist.title.lowercased().contains(q) ||
            playlist.tracks.contains { $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) }
        }
    }

    /// Tracks matching search query (shown when searching)
    private var matchingTracks: [(Track, Playlist)] {
        guard !searchText.isEmpty else { return [] }
        let q = searchText.lowercased()
        var results: [(Track, Playlist)] = []
        for playlist in receiver.availablePlaylists {
            for track in playlist.tracks where track.title.lowercased().contains(q) || track.artist.lowercased().contains(q) {
                if !results.contains(where: { $0.0.videoId == track.videoId }) {
                    results.append((track, playlist))
                }
            }
        }
        return Array(results.prefix(20))
    }

    /// Recently played smart playlist
    private var recentlyPlayedPlaylist: Playlist? {
        let recents = player.recentlyPlayed
        guard !recents.isEmpty else { return nil }
        let ids = receiver.cachedOrFreshTrackIds()
        let tracks = recents.prefix(30).compactMap { recent -> Track? in
            guard ids.contains(recent.trackVideoId) else { return nil }
            return recent.asTrack
        }
        guard !tracks.isEmpty else { return nil }
        return Playlist(id: "__recently_played__", title: "Recently Played", thumbnailURL: nil, tracks: tracks)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if receiver.availablePlaylists.isEmpty && !showSearch {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.system(size: 28, weight: .ultraLight))
                            .foregroundStyle(Color(white: 0.25))
                        Text("No music yet")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(white: 0.6))
                        Text("Sync a playlist from the iPhone app.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(white: 0.3))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            // Resume indicator
                            if !player.isPlaying, player.currentTrack != nil, player.currentTime > 5 {
                                ResumeIndicator()
                            }

                            // Now playing bar
                            if let track = player.currentTrack, player.isPlaying {
                                NavigationLink(destination: NowPlayingScreen()) {
                                    NowPlayingBanner(track: track)
                                }
                                .buttonStyle(.plain)
                            }

                            // Search bar
                            Button {
                                withAnimation { showSearch.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("Search")
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                }
                                .foregroundStyle(Color(white: 0.4))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color(white: 0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)

                            if showSearch {
                                TextField("Songs, artists…", text: $searchText)
                                    .font(.system(size: 12))
                                    .textFieldStyle(.plain)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color(white: 0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }

                            // Search results: matching tracks
                            if !searchText.isEmpty {
                                let tracks = matchingTracks
                                if !tracks.isEmpty {
                                    SectionLabel(title: "Tracks")
                                    ForEach(tracks, id: \.0.videoId) { (track, playlist) in
                                        Button {
                                            if let idx = playlist.tracks.firstIndex(where: { $0.videoId == track.videoId }) {
                                                player.load(playlist: playlist, startAt: idx)
                                            }
                                        } label: {
                                            SearchTrackRow(track: track, playlistTitle: playlist.title)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }

                                let playlists = filteredPlaylists
                                if !playlists.isEmpty {
                                    SectionLabel(title: "Playlists")
                                }
                            }

                            // Shuffle All — play every downloaded track in random order
                            if searchText.isEmpty && !receiver.availablePlaylists.isEmpty {
                                Button {
                                    player.playAllShuffled()
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "shuffle")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(.white)
                                        Text("Shuffle All")
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                        Spacer()
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.85))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 11)
                                    .background(
                                        LinearGradient(
                                            colors: [Color.ytRed, Color.ytRed.opacity(0.65)],
                                            startPoint: .leading, endPoint: .trailing
                                        )
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }

                            // Recently Played smart playlist
                            if searchText.isEmpty, let recent = recentlyPlayedPlaylist {
                                NavigationLink(destination: TrackListView(playlist: recent)) {
                                    SmartPlaylistRow(title: "Recently Played", icon: "clock.arrow.circlepath", count: recent.tracks.count)
                                }
                                .buttonStyle(.plain)
                            }

                            // Playlists
                            ForEach(searchText.isEmpty ? receiver.availablePlaylists : filteredPlaylists) { playlist in
                                NavigationLink(destination: TrackListView(playlist: playlist)) {
                                    WatchPlaylistRow(playlist: playlist)
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        receiver.deletePlaylist(playlist)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }

                            // Navigation links
                            HStack(spacing: 8) {
                                NavigationLink(destination: StorageManagementView()) {
                                    StorageIndicator(usedMB: receiver.usedMB)
                                }
                                .buttonStyle(.plain)

                                if player.sleepTimerRemaining != nil {
                                    NavigationLink(destination: SleepTimerView()) {
                                        SleepTimerBadge()
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 8)

                            // Sleep timer + Settings row
                            if player.sleepTimerRemaining == nil {
                                NavigationLink(destination: SleepTimerView()) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "moon.zzz")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(Color(white: 0.3))
                                        Text("Sleep Timer")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(Color(white: 0.3))
                                    }
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 2)
                            }

                            // Auto-play similar toggle — keep music going when a playlist ends
                            Toggle(isOn: $player.autoPlaySimilar) {
                                HStack(spacing: 6) {
                                    Image(systemName: "infinity")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Color.ytRed)
                                    Text("Auto-Play Similar")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color(white: 0.7))
                                }
                            }
                            .tint(Color.ytRed)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("YTWatch")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if isRefreshing {
                        ProgressView()
                            .tint(Color.ytRed)
                            .scaleEffect(0.6)
                    } else {
                        Button {
                            isRefreshing = true
                            receiver.rescanFiles(force: true)
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                withAnimation { isRefreshing = false }
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color(white: 0.5))
                        }
                    }
                }
            }
            .onAppear { receiver.rescanFiles() }
            // Sync progress overlay
            .overlay(alignment: .bottomTrailing) {
                if receiver.receivingCount > 0 {
                    SyncProgressBadge()
                        .padding(8)
                }
            }
            // Track change toast overlay
            .overlay(alignment: .top) {
                if let toast = player.trackChangeToast {
                    TrackChangeToast(track: toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.3), value: player.trackChangeToast?.videoId)
        }
    }
}

// MARK: - Resume Indicator

private struct ResumeIndicator: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        if let track = player.currentTrack {
            Button {
                player.play()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color.ytRed)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Continue")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color(white: 0.5))
                        Text(track.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(white: 0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.ytRed.opacity(0.15), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Track Change Toast

private struct TrackChangeToast: View {
    let track: Track

    var body: some View {
        HStack(spacing: 6) {
            if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.ytRed)
                    .frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 8))
                    .foregroundStyle(Color(white: 0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .padding(.top, 2)
    }
}

// MARK: - Sync Progress Badge

private struct SyncProgressBadge: View {
    @ObservedObject private var receiver = WatchFileReceiver.shared

    var body: some View {
        HStack(spacing: 4) {
            ProgressView().scaleEffect(0.6).tint(Color.ytRed)
            VStack(alignment: .leading, spacing: 0) {
                if let name = receiver.syncingPlaylistName {
                    Text(name)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(white: 0.6))
                        .lineLimit(1)
                }
                if receiver.syncedTrackCount > 0 {
                    Text("\(receiver.syncedTrackCount) tracks synced")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color(white: 0.4))
                } else {
                    Text("Syncing…")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color(white: 0.4))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.08))
        .clipShape(Capsule())
    }
}

// MARK: - Sleep Timer Badge

private struct SleepTimerBadge: View {
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.purple)
            if player.isSleepTimerEndOfTrack {
                Text("End of track")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Color(white: 0.5))
            } else if let remaining = player.sleepTimerRemaining {
                Text(formatTimer(remaining))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.purple.opacity(0.1))
        .clipShape(Capsule())
    }

    private func formatTimer(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}

// MARK: - Search Track Row

private struct SearchTrackRow: View {
    let track: Track
    let playlistTitle: String

    var body: some View {
        HStack(spacing: 8) {
            if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color(white: 0.12))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: 9, weight: .light))
                            .foregroundStyle(Color(white: 0.3))
                    )
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(track.artist) · \(playlistTitle)")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(white: 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Section Label

private struct SectionLabel: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(white: 0.4))
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.top, 6)
        .padding(.horizontal, 4)
    }
}

// MARK: - Smart Playlist Row

private struct SmartPlaylistRow: View {
    let title: String
    let icon: String
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    LinearGradient(colors: [Color.ytRed.opacity(0.3), Color.purple.opacity(0.2)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text("\(count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.38))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Now Playing Banner

private struct NowPlayingBanner: View {
    let track: Track
    @ObservedObject private var player = WatchPlayer.shared

    var body: some View {
        HStack(spacing: 8) {
            if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.ytRed)
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 9))
                    .foregroundStyle(Color(white: 0.45))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.25))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [Color.ytRed.opacity(0.15), Color(white: 0.07)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.ytRed.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Storage Indicator

private struct StorageIndicator: View {
    let usedMB: Double

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(white: 0.3))
            Text(String(format: "%.0f MB", usedMB))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color(white: 0.3))
        }
    }
}

// MARK: - Playlist Row

private struct WatchPlaylistRow: View {
    let playlist: Playlist

    private var firstThumbImage: UIImage? {
        for track in playlist.tracks {
            if let img = WatchThumbnailCache.shared.image(for: track.videoId) {
                return img
            }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            if let img = firstThumbImage {
                Image(uiImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(white: 0.15))
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: "music.note.list")
                            .font(.system(size: 12, weight: .light))
                            .foregroundStyle(Color(white: 0.3))
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("\(playlist.tracks.count) tracks")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(white: 0.38))
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color(white: 0.2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(white: 0.09))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
