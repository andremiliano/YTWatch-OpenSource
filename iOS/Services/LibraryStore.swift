import Foundation

@MainActor
final class LibraryStore: ObservableObject {

    static let shared = LibraryStore()

    @Published var playlists: [Playlist] = []
    @Published var librarySongs: [Track] = []
    @Published var isLoading = false
    @Published var error: String?

    private let cacheURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("library_cache.json")

    /// Throttle auto-refreshes — prevents view re-appearances from constantly stomping library
    private var lastRefreshAt: Date?
    private static let refreshCooldown: TimeInterval = 300 // 5 minutes

    init() { loadFromDisk() }

    /// Auto-refresh called from view .task — throttled to prevent constant stomping.
    func refreshIfStale() async {
        if let last = lastRefreshAt, Date().timeIntervalSince(last) < Self.refreshCooldown {
            return // recently refreshed, skip
        }
        await refresh()
    }

    /// Explicit refresh from user action (pull-to-refresh button) — always runs.
    func refresh() async {
        guard YTMusicClient.shared.isAuthenticated, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        error = nil
        lastRefreshAt = Date()
        async let songsTask: Void = fetchLibrarySongs()
        do {
            let shells = try await YTMusicClient.shared.fetchLibraryPlaylists()
            // Preserve existing playlist order — only add new playlists at the end.
            // Stops the library from "jumping around" when YouTube returns a different order.
            let existingIds = playlists.map(\.id)
            let shellById = Dictionary(uniqueKeysWithValues: shells.map { ($0.id, $0) })

            var updated: [Playlist] = []
            // Keep existing playlists in their current order (if still present in remote)
            for existing in playlists {
                if let shell = shellById[existing.id] {
                    var merged = shell
                    merged.tracks = existing.tracks // preserve cached tracks
                    updated.append(merged)
                }
            }
            // Append new playlists at the end
            for shell in shells where !existingIds.contains(shell.id) {
                updated.append(shell)
            }
            playlists = updated
            await fetchTracksInBackground(for: shells)
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        _ = await songsTask
        saveToDisk()
    }

    private func fetchLibrarySongs() async {
        librarySongs = (try? await YTMusicClient.shared.fetchLibrarySongs()) ?? []
    }

    private func fetchTracksInBackground(for shells: [Playlist]) async {
        var updated = playlists
        let maxConcurrent = 4
        var playlistsToAutoUpdate: [(Playlist, [Track])] = []

        await withTaskGroup(of: (String, [Track]).self) { group in
            for (i, playlist) in shells.enumerated() {
                if i >= maxConcurrent { _ = await group.next() }
                group.addTask {
                    let tracks = (try? await YTMusicClient.shared.fetchPlaylistTracks(playlistId: playlist.id)) ?? []
                    return (playlist.id, tracks)
                }
            }
            for await (id, tracks) in group {
                if let idx = updated.firstIndex(where: { $0.id == id }) {
                    let oldTracks = updated[idx].tracks
                    updated[idx].tracks = tracks

                    let downloader = AudioDownloader.shared
                    let hasDownloads = oldTracks.contains { downloader.isDownloaded($0.videoId) }
                    if hasDownloads {
                        let newTracks = tracks.filter { t in
                            !oldTracks.contains(where: { $0.videoId == t.videoId }) && !downloader.isDownloaded(t.videoId)
                        }
                        if !newTracks.isEmpty {
                            playlistsToAutoUpdate.append((updated[idx], newTracks))
                        }
                    }
                }
            }
        }
        // Preserve existing order — do NOT re-sort (was causing library "jumping around")
        playlists = updated
        saveToDisk()

        for (playlist, newTracks) in playlistsToAutoUpdate {
            await autoDownloadNewTracks(newTracks, playlist: playlist)
        }
    }

    private func autoDownloadNewTracks(_ tracks: [Track], playlist: Playlist) async {
        print("[Library] Auto-downloading \(tracks.count) new tracks for \(playlist.title)")

        await withTaskGroup(of: Void.self) { group in
            for track in tracks {
                group.addTask {
                    _ = try? await AudioDownloader.shared.download(track: track, playlistId: playlist.id, playlistTitle: playlist.title)
                }
            }
        }

        if WatchSyncManager.shared.isAvailable {
            WatchSyncManager.shared.syncPlaylist(playlist)
        }
    }

    struct LibraryCache: Codable {
        let playlists: [Playlist]
        let librarySongs: [Track]
    }

    private func saveToDisk() {
        let cache = LibraryCache(playlists: playlists, librarySongs: librarySongs)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        // Atomic so a kill mid-write can't leave truncated JSON that loses the library.
        try? data.write(to: cacheURL, options: .atomic)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        if let cache = try? JSONDecoder().decode(LibraryCache.self, from: data) {
            playlists = cache.playlists
            librarySongs = cache.librarySongs
        } else if let decoded = try? JSONDecoder().decode([Playlist].self, from: data) {
            playlists = decoded
        }
    }
}
