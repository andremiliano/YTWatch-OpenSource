//
//  WatchFileReceiver.swift
//  YTWatch
//
//  Receives audio files and playlist metadata from the iPhone companion app.
//
//  Architecture Notes:
//  - Uses `WCSession` to receive large audio payloads in the background.
//  - Implements lazy disk scanning (`FileManager.enumerator`) to avoid memory footprint spikes 
//    when validating thousands of tracks on launch.
//  - Defers batch UI state updates until transfers complete to prevent UI hangs.
//

import Foundation
import WatchConnectivity
import AVFoundation

@MainActor
final class WatchFileReceiver: NSObject, ObservableObject {

    static let shared = WatchFileReceiver()

    @Published var playlists: [Playlist] = []
    @Published var receivingCount = 0
    @Published var syncingPlaylistName: String? = nil
    @Published var syncedTrackCount = 0
    @Published var syncTotalCount = 0
    /// Cached available playlists — only tracks with files on disk. Call `refreshAvailable()` to update.
    @Published private(set) var cachedAvailablePlaylists: [Playlist] = []
    private var _cachedTrackIds: Set<String>?

    private let fm = FileManager.default

    static var audioDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Audio", isDirectory: true)
    }

    static var thumbnailDirectory: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    private static var fm: FileManager { .default }

    override init() {
        super.init()
        createDirectories()
        loadPlaylistsFromDisk()
        // Merge any pre-existing duplicate playlists by title (one-time cleanup on launch)
        let beforeCount = playlists.count
        consolidateDuplicateTitles()
        if playlists.count != beforeCount {
            savePlaylistsToDisk()
        }
        refreshAvailable()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        validateDownloadsOnLaunch()
    }

    // MARK: - Launch Validation & Self-Heal

    /// On launch, verify every downloaded file is intact and playable. Corrupt/truncated
    /// files are deleted and the phone is asked to re-send them. Runs in the background,
    /// throttled, so it never blocks the UI. This keeps a bad file from crashing playback.
    private static let validatedKey = "validatedTrackIds"

    func validateDownloadsOnLaunch() {
        Task { @MainActor in
            let ids = Array(availableTrackIds() ?? [])
            guard !ids.isEmpty else { return }
            var validated = Set(UserDefaults.standard.stringArray(forKey: Self.validatedKey) ?? [])
            var corrupt: [String] = []
            var newlyValidated: [String] = []

            for (i, id) in ids.enumerated() {
                if i % 5 == 4 { try? await Task.sleep(nanoseconds: 30_000_000) } // yield, never hitch UI
                let url = Self.audioDirectory.appendingPathComponent("\(id).m4a")
                // Fast check every launch: size catches truncated/interrupted downloads.
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if !AudioFileGate.isValid(sizeBytes: size) {
                    corrupt.append(id)
                    continue
                }
                // Deep playability check only once per file (cached), so later launches are cheap.
                if validated.contains(id) { continue }
                if await Self.isPlayable(url) {
                    newlyValidated.append(id)
                } else {
                    corrupt.append(id)
                }
            }

            if !newlyValidated.isEmpty {
                validated.formUnion(newlyValidated)
            }
            if corrupt.isEmpty {
                UserDefaults.standard.set(Array(validated), forKey: Self.validatedKey)
                print("[Receiver] Launch validation: all \(ids.count) files OK")
                return
            }

            print("[Receiver] Launch validation: \(corrupt.count) corrupt/unplayable — deleting + requesting re-download")
            for id in corrupt {
                try? fm.removeItem(at: Self.audioDirectory.appendingPathComponent("\(id).m4a"))
                validated.remove(id)
            }
            UserDefaults.standard.set(Array(validated), forKey: Self.validatedKey)
            _cachedTrackIds = nil
            refreshAvailable()
            requestRedownload(videoIds: corrupt)
        }
    }

    /// Validate that AVFoundation can actually play a file (catches non-truncated corruption).
    nonisolated static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            let duration = try await asset.load(.duration)
            return playable && !duration.seconds.isNaN && duration.seconds > 0
        } catch {
            return false
        }
    }

    /// Ask the phone to re-send specific tracks (missing or corrupt on the Watch).
    func requestRedownload(videoIds: [String]) {
        guard !videoIds.isEmpty, WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.requestRedownload.rawValue,
            "videoIds": videoIds
        ]
        // transferUserInfo is queued + reliable even if the phone app isn't foreground
        WCSession.default.transferUserInfo(msg)
    }

    // MARK: - Public

    func audioURL(for videoId: String) -> URL? {
        let url = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func thumbnailURL(for videoId: String) -> URL? {
        let url = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
        return fm.fileExists(atPath: url.path) ? url : nil
    }

    func deletePlaylist(_ playlist: Playlist) {
        // Collect track IDs used by OTHER playlists so we don't delete shared files
        let otherTrackIds = Set(playlists.filter { $0.id != playlist.id }.flatMap { $0.tracks.map(\.videoId) })
        for track in playlist.tracks where !otherTrackIds.contains(track.videoId) {
            let audio = Self.audioDirectory.appendingPathComponent("\(track.videoId).m4a")
            let thumb = Self.thumbnailDirectory.appendingPathComponent("\(track.videoId).jpg")
            try? fm.removeItem(at: audio)
            try? fm.removeItem(at: thumb)
        }
        playlists.removeAll { $0.id == playlist.id }
        savePlaylistsToDisk()
        _cachedTrackIds = nil
        refreshAvailable()
    }

    func isAvailable(_ videoId: String) -> Bool {
        audioURL(for: videoId) != nil
    }

    private var lastRescanDate: Date?
    /// Matches the cooldown iOS's LibraryStore.refreshIfStale() uses for the same reason:
    /// this view's .onAppear fires on every root-view re-composition (launch, returning
    /// from Now Playing/Settings, etc. — watchOS recomposes more eagerly than iOS), and
    /// without a cooldown each one re-ran a full directory scan + JSON reload right as
    /// the user was likely about to tap a track.
    private static let rescanCooldown: TimeInterval = 300

    /// - Parameter force: bypass the cooldown — used by the manual pull/refresh button.
    func rescanFiles(force: Bool = false) {
        if !force, let last = lastRescanDate, Date().timeIntervalSince(last) < Self.rescanCooldown {
            return
        }
        lastRescanDate = Date()
        loadPlaylistsFromDisk()

        // Discover audio files on disk not in any playlist
        let knownIds = Set(playlists.flatMap { $0.tracks.map(\.videoId) })
        let onDisk = availableTrackIds() ?? []
        let orphaned = onDisk.subtracting(knownIds)

        if !orphaned.isEmpty {
            // Add orphaned tracks to an "Unsorted" playlist
            let unsortedId = "__unsorted__"
            var unsorted = playlists.first(where: { $0.id == unsortedId }) ?? Playlist(
                id: unsortedId, title: "Unsorted", thumbnailURL: nil, tracks: []
            )
            for videoId in orphaned {
                if !unsorted.tracks.contains(where: { $0.videoId == videoId }) {
                    let track = Track(id: videoId, videoId: videoId, title: videoId, artist: "Unknown", durationSeconds: 0)
                    unsorted.tracks.append(track)
                }
            }
            upsertPlaylist(unsorted)
            print("[Receiver] Found \(orphaned.count) orphaned audio files, added to Unsorted")
        }

        refreshAvailable()
    }

    func availableTrackIds() -> Set<String>? {
        guard let enumerator = fm.enumerator(at: Self.audioDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
            print("[Receiver] Error reading directory or directory does not exist.")
            return nil
        }
        var entries: [(id: String, sizeBytes: Int)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "m4a" else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            entries.append((id: url.deletingPathExtension().lastPathComponent, sizeBytes: size))
        }
        // Truncated/partially-written files are filtered here so they never enter the
        // shuffle/play queue — playTrack would reject them anyway, but only after
        // they're already selected, which chains into skip/crash loops.
        return AudioFileGate.filterValid(entries)
    }

    // Filter playlists to only tracks actually on device
    var availablePlaylists: [Playlist] {
        cachedAvailablePlaylists
    }

    func refreshAvailable() {
        guard let ids = availableTrackIds() else {
            print("[Receiver] Failed to read audio directory. Keeping existing cached tracks.")
            return
        }
        _cachedTrackIds = ids
        rebuildCachedAvailablePlaylists(using: ids)
    }

    private func rebuildCachedAvailablePlaylists(using ids: Set<String>) {
        cachedAvailablePlaylists = playlists.compactMap { playlist -> Playlist? in
            var p = playlist
            p.tracks = playlist.tracks.filter { ids.contains($0.videoId) }
            return p.tracks.isEmpty ? nil : p
        }
    }

    /// Re-derives `cachedAvailablePlaylists` from the current `_cachedTrackIds` — no disk
    /// scan. Use this after a metadata-only change to `playlists` (e.g. healing a track's
    /// duration) that can't change which files are actually on disk, instead of
    /// `refreshAvailable()`'s full directory rescan. That distinction matters here: this
    /// runs from WatchPlayer's `.readyToPlay` handler on effectively every track start for
    /// any legacy download with a missing duration, so a full rescan there was blocking
    /// `player.play()` on a synchronous scan of the whole library right at playback start.
    func syncCachedAvailablePlaylistsFromMemory() {
        rebuildCachedAvailablePlaylists(using: cachedOrFreshTrackIds())
    }

    /// Cached available track IDs — avoids disk scan per call
    func cachedOrFreshTrackIds() -> Set<String> {
        if let cached = _cachedTrackIds { return cached }
        
        if let ids = availableTrackIds() {
            _cachedTrackIds = ids
            return ids
        } else {
            // If the disk is unreadable (e.g. watch is locked with FileProtection), 
            // fall back to the IDs we already know are in our available playlists.
            let fallback = Set(cachedAvailablePlaylists.flatMap { $0.tracks.map(\.videoId) })
            return fallback
        }
    }

    // MARK: - Storage

    var usedBytes: Int64 {
        var total: Int64 = 0
        if let enumerator = fm.enumerator(at: Self.audioDirectory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    var usedMB: Double { Double(usedBytes) / 1_000_000 }

    func storageMB(for playlist: Playlist) -> Double {
        var total: Int64 = 0
        for track in playlist.tracks {
            let url = Self.audioDirectory.appendingPathComponent("\(track.videoId).m4a")
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            total += Int64(size)
        }
        return Double(total) / 1_000_000
    }

    var totalDeviceStorageMB: Double {
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let total = (attrs?[.systemSize] as? Int64) ?? 0
        return Double(total) / 1_000_000
    }

    var freeDeviceStorageMB: Double {
        let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory())
        let free = (attrs?[.systemFreeSize] as? Int64) ?? 0
        return Double(free) / 1_000_000
    }

    // MARK: - Direct WiFi Download

    /// Max concurrent direct downloads on Watch. Kept low — the Watch has very
    /// little RAM and each concurrent download + write adds memory pressure.
    private static let maxWatchDownloads = 2
    @Published var directDownloadCount = 0
    private var directDownloadQueue: [DirectDownloadPayload] = []

    private func handleDirectDownload(_ payload: DirectDownloadPayload) {
        let videoId = payload.track.videoId

        // Skip if already have this track
        guard audioURL(for: videoId) == nil else {
            sendDownloadResult(videoId: videoId, success: true)
            upsertTrackIntoPlaylistDeferred(payload)
            scheduleLibraryFlush()
            return
        }

        // Queue if at capacity
        if directDownloadCount >= Self.maxWatchDownloads {
            if !directDownloadQueue.contains(where: { $0.track.videoId == videoId }) {
                directDownloadQueue.append(payload)
                print("[Receiver] Queued WiFi download (\(directDownloadQueue.count) waiting): \(payload.track.title)")
            }
            return
        }

        startDirectDownload(payload)
    }

    private func startDirectDownload(_ payload: DirectDownloadPayload) {
        let videoId = payload.track.videoId
        receivingCount += 1
        directDownloadCount += 1
        syncingPlaylistName = payload.playlistTitle
        syncTotalCount += 1

        Task {
            do {
                guard let streamURL = URL(string: payload.streamURL) else {
                    throw URLError(.badURL)
                }
                var request = URLRequest(url: streamURL)
                for (key, value) in payload.headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
                request.timeoutInterval = 120

                // Stream to a temp file on disk instead of loading the whole audio into
                // RAM — critical on the memory-constrained Watch (prevents OOM crashes).
                let (tempURL, response) = try await URLSession.shared.download(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                guard (200...299).contains(status), size > 0 else {
                    try? fm.removeItem(at: tempURL)
                    throw URLError(.badServerResponse)
                }

                let destURL = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
                try? fm.removeItem(at: destURL)
                try fm.moveItem(at: tempURL, to: destURL)

                // Download thumbnail (also streamed to disk)
                if let thumbURLStr = payload.thumbnailDownloadURL,
                   let thumbURL = URL(string: thumbURLStr) {
                    if let (thumbTemp, thumbResp) = try? await URLSession.shared.download(from: thumbURL),
                       (thumbResp as? HTTPURLResponse).map({ (200...299).contains($0.statusCode) }) ?? true {
                        let thumbDest = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
                        try? fm.removeItem(at: thumbDest)
                        try? fm.moveItem(at: thumbTemp, to: thumbDest)
                    }
                }

                upsertTrackIntoPlaylistDeferred(payload)
                scheduleLibraryFlush()
                syncedTrackCount += 1

                print("[Receiver] WiFi download ✓ \(payload.track.title) (\(syncedTrackCount)/\(syncTotalCount))")
                sendDownloadResult(videoId: videoId, success: true)

            } catch {
                print("[Receiver] WiFi download ✘ \(videoId): \(error.localizedDescription)")
                sendDownloadResult(videoId: videoId, success: false)
            }

            // Decrement and process next queued download
            self.receivingCount = max(0, self.receivingCount - 1)
            self.directDownloadCount = max(0, self.directDownloadCount - 1)
            self.processNextDirectDownload()

            if self.receivingCount == 0 {
                // Clear sync progress after a delay
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.receivingCount == 0 {
                    self.syncingPlaylistName = nil
                    self.syncedTrackCount = 0
                    self.syncTotalCount = 0
                }
            }
        }
    }

    private func processNextDirectDownload() {
        while directDownloadCount < Self.maxWatchDownloads && !directDownloadQueue.isEmpty {
            let next = directDownloadQueue.removeFirst()
            // Skip if already downloaded while queued
            if audioURL(for: next.track.videoId) != nil {
                sendDownloadResult(videoId: next.track.videoId, success: true)
                upsertTrackIntoPlaylistDeferred(next)
                scheduleLibraryFlush()
                continue
            }
            startDirectDownload(next)
            break
        }
    }

    /// In-memory-only variant of `upsertTrackIntoPlaylist` — no disk write, no directory
    /// rescan. Direct WiFi downloads can complete in a fast burst (multiple concurrent
    /// downloads, or a long run of "already downloaded, just attach metadata" skips), and
    /// each one used to trigger a full savePlaylistsToDisk() + refreshAvailable() — the
    /// exact same "N operations -> N disk writes + N directory scans -> Watch crash" bug
    /// already fixed once for the playlistIndex path via upsertPlaylistsBatch (see
    /// didReceiveApplicationContext). Callers must pair this with scheduleLibraryFlush().
    private func upsertTrackIntoPlaylistDeferred(_ payload: DirectDownloadPayload) {
        if var playlist = playlists.first(where: { $0.id == payload.playlistId }) {
            if !playlist.tracks.contains(where: { $0.videoId == payload.track.videoId }) {
                let idx = payload.indexInPlaylist
                if idx >= 0 && idx <= playlist.tracks.count {
                    playlist.tracks.insert(payload.track, at: min(idx, playlist.tracks.count))
                } else {
                    playlist.tracks.append(payload.track)
                }
            }
            upsertPlaylistDeferred(playlist)
        } else {
            let newPlaylist = Playlist(
                id: payload.playlistId,
                title: payload.playlistTitle,
                thumbnailURL: nil,
                tracks: [payload.track]
            )
            upsertPlaylistDeferred(newPlaylist)
        }
    }

    private var libraryFlushPending = false

    /// Coalesces bursts of upsertTrackIntoPlaylistDeferred calls into a single
    /// savePlaylistsToDisk() + refreshAvailable() ~300ms after the last one, instead of
    /// doing that expensive work per-track.
    private func scheduleLibraryFlush() {
        guard !libraryFlushPending else { return }
        libraryFlushPending = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard self.libraryFlushPending else { return }
            self.libraryFlushPending = false
            self.savePlaylistsToDisk()
            self._cachedTrackIds = nil
            self.refreshAvailable()
        }
    }

    private func sendDownloadResult(videoId: String, success: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.downloadResult.rawValue,
            "videoId": videoId,
            "success": success
        ]
        // Use transferUserInfo for reliability (sendMessage may fail if phone app not foreground)
        WCSession.default.transferUserInfo(msg)
    }

    // MARK: - Private

    private func createDirectories() {
        try? fm.createDirectory(at: Self.audioDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.thumbnailDirectory, withIntermediateDirectories: true)
    }

    private func loadPlaylistsFromDisk() {
        let url = cacheURL()
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = decoded
    }

    private func savePlaylistsToDisk() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: cacheURL())
    }

    private func cacheURL() -> URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists_cache.json")
    }

    /// Normalize title for duplicate detection (trim + lowercase).
    private static func normalizeTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func upsertPlaylist(_ playlist: Playlist) {
        // ID match → REPLACE (caller is authoritative for that playlist's full state).
        // File-receive path always passes the FULL augmented playlist, so no loss here.
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        }
        // No ID match but same TITLE exists → MERGE into existing (the duplicate fix).
        else if let idx = playlists.firstIndex(where: { Self.normalizeTitle($0.title) == Self.normalizeTitle(playlist.title) }) {
            playlists[idx] = mergeTracks(into: playlists[idx], from: playlist)
        } else {
            playlists.append(playlist)
        }
        savePlaylistsToDisk()
        _cachedTrackIds = nil
        refreshAvailable()
    }

    private func upsertPlaylistDeferred(_ playlist: Playlist) {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        }
        else if let idx = playlists.firstIndex(where: { Self.normalizeTitle($0.title) == Self.normalizeTitle(playlist.title) }) {
            playlists[idx] = mergeTracks(into: playlists[idx], from: playlist)
        } else {
            playlists.append(playlist)
        }
    }

    /// Batch upsert — saves disk once, refreshes once.
    /// ID match = replace (authoritative). Title match (different ID) = merge tracks.
    private func upsertPlaylistsBatch(_ incoming: [Playlist]) {
        for p in incoming {
            if let idx = playlists.firstIndex(where: { $0.id == p.id }) {
                playlists[idx] = mergeTracks(into: playlists[idx], from: p) // ID match: preserve local tracks
            } else if let idx = playlists.firstIndex(where: { Self.normalizeTitle($0.title) == Self.normalizeTitle(p.title) }) {
                playlists[idx] = mergeTracks(into: playlists[idx], from: p) // title match: merge
            } else {
                playlists.append(p)
            }
        }
        // Final pass: dedupe any pre-existing same-name playlists
        consolidateDuplicateTitles()
        savePlaylistsToDisk()
        _cachedTrackIds = nil
        refreshAvailable()
    }

    /// Merge tracks from source into target. Preserves target's id+title, adds unique videoIds.
    /// Uses target's thumbnail if present, else source's.
    private func mergeTracks(into target: Playlist, from source: Playlist) -> Playlist {
        var combined = target.tracks
        let existingIds = Set(target.tracks.map(\.videoId))
        for track in source.tracks where !existingIds.contains(track.videoId) {
            combined.append(track)
        }
        let thumb: String?
        if let t = target.thumbnailURL, !t.isEmpty {
            thumb = t
        } else {
            thumb = source.thumbnailURL
        }
        return Playlist(
            id: target.id, title: target.title, subtitle: target.subtitle,
            thumbnailURL: thumb, tracks: combined
        )
    }

    /// Walks playlist list and merges any with the same normalized title.
    /// Called on launch and after batch upserts to clean up legacy duplicates.
    func consolidateDuplicateTitles() {
        var grouped: [String: [Int]] = [:]
        for (idx, p) in playlists.enumerated() {
            grouped[Self.normalizeTitle(p.title), default: []].append(idx)
        }
        guard grouped.values.contains(where: { $0.count > 1 }) else { return }

        var result: [Playlist] = []
        var processedTitles = Set<String>()
        for p in playlists {
            let key = Self.normalizeTitle(p.title)
            if processedTitles.contains(key) { continue }
            processedTitles.insert(key)

            let allWithName = playlists.filter { Self.normalizeTitle($0.title) == key }
            if allWithName.count == 1 {
                result.append(p)
            } else {
                // Merge all — keep first playlist's id/title, dedupe tracks, prefer first non-empty thumb
                let first = allWithName[0]
                var combinedTracks = first.tracks
                var added = Set(first.tracks.map(\.videoId))
                var thumb = first.thumbnailURL
                for other in allWithName.dropFirst() {
                    for track in other.tracks where !added.contains(track.videoId) {
                        combinedTracks.append(track)
                        added.insert(track.videoId)
                    }
                    if (thumb?.isEmpty ?? true), let t = other.thumbnailURL, !t.isEmpty {
                        thumb = t
                    }
                }
                result.append(Playlist(
                    id: first.id, title: first.title, subtitle: first.subtitle,
                    thumbnailURL: thumb, tracks: combinedTracks
                ))
            }
        }
        if result.count != playlists.count {
            print("[Receiver] Merged \(playlists.count - result.count) duplicate playlists by title")
            playlists = result
        }
    }

    /// Heal old-version downloads that were saved with durationSeconds=0.
    /// Called when the player reads a real duration from the audio file.
    func updateTrackDuration(videoId: String, duration: Int) {
        guard duration > 0 else { return }
        var changed = false
        for pIdx in playlists.indices {
            for tIdx in playlists[pIdx].tracks.indices
            where playlists[pIdx].tracks[tIdx].videoId == videoId
                && playlists[pIdx].tracks[tIdx].durationSeconds != duration {
                let old = playlists[pIdx].tracks[tIdx]
                // Only fill in when missing (0) — never override a real API-sourced value
                guard old.durationSeconds <= 0 else { continue }
                playlists[pIdx].tracks[tIdx] = Track(
                    id: old.id, videoId: old.videoId, title: old.title, artist: old.artist,
                    album: old.album, durationSeconds: duration, thumbnailURL: old.thumbnailURL,
                    artistId: old.artistId, albumId: old.albumId
                )
                changed = true
            }
        }
        if changed {
            savePlaylistsToDisk()
            syncCachedAvailablePlaylistsFromMemory()
        }
    }

    /// Delete ONLY the audio file (keep the playlist entry) when playback finds it corrupt.
    /// The track stays listed but shows as unavailable, so Verify & Re-sync will re-send it.
    func deleteCorruptAudioFile(videoId: String) {
        let audio = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
        try? fm.removeItem(at: audio)
        _cachedTrackIds = nil
        refreshAvailable()
        print("[Receiver] Removed corrupt file \(videoId) — will re-sync on next verify")
    }

    func deleteTrack(videoId: String) {
        let audio = Self.audioDirectory.appendingPathComponent("\(videoId).m4a")
        let thumb = Self.thumbnailDirectory.appendingPathComponent("\(videoId).jpg")
        try? fm.removeItem(at: audio)
        try? fm.removeItem(at: thumb)
        for i in playlists.indices {
            playlists[i].tracks.removeAll { $0.videoId == videoId }
        }
        playlists.removeAll { $0.tracks.isEmpty }
        savePlaylistsToDisk()
        _cachedTrackIds = nil
        refreshAvailable()
    }

    func cleanupOrphanedFiles() {
        // Don't cleanup while actively receiving files — race condition
        guard receivingCount == 0 else {
            print("[Receiver] Skipping cleanup — \(receivingCount) files being received")
            return
        }
        let allTrackIds = Set(playlists.flatMap { $0.tracks.map(\.videoId) })
        let onDisk = availableTrackIds() ?? []
        let orphans = onDisk.subtracting(allTrackIds)
        guard !orphans.isEmpty else { return }
        // Delay cleanup to give pending transfers time to register
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            // Re-check after delay — new playlists may have been upserted
            let currentTrackIds = Set(self.playlists.flatMap { $0.tracks.map(\.videoId) })
            let stillOrphaned = orphans.subtracting(currentTrackIds)
            guard self.receivingCount == 0 else { return }
            for id in stillOrphaned {
                let audioFile = Self.audioDirectory.appendingPathComponent("\(id).m4a")
                let thumbFile = Self.thumbnailDirectory.appendingPathComponent("\(id).jpg")
                try? self.fm.removeItem(at: audioFile)
                try? self.fm.removeItem(at: thumbFile)
            }
            if !stillOrphaned.isEmpty {
                print("[Receiver] Cleaned up \(stillOrphaned.count) orphaned files")
            }
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchFileReceiver: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}

    // Receive audio or thumbnail file
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let fileURL = file.fileURL
        let metaData: Data? = file.metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        let isThumbnail = (file.metadata?["isThumbnail"] as? Bool) == true

        guard let metaData,
              let transfer = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) else { return }

        let wroteSuccessfully: Bool
        let isThumb = isThumbnail

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        if isThumbnail {
            let thumbDest = docs.appendingPathComponent("Thumbnails", isDirectory: true).appendingPathComponent("\(transfer.track.videoId).jpg")
            try? fm.removeItem(at: thumbDest)
            do {
                try fm.copyItem(at: fileURL, to: thumbDest)
                wroteSuccessfully = true
            } catch {
                print("[Receiver] BT write failed for thumbnail \(transfer.track.videoId): \(error.localizedDescription)")
                wroteSuccessfully = false
            }
        } else {
            let destURL = docs.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent("\(transfer.track.videoId).m4a")
            try? fm.removeItem(at: destURL)
            do {
                try fm.copyItem(at: fileURL, to: destURL)
                // Verify file is non-empty
                let size = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                wroteSuccessfully = AudioFileGate.isValid(sizeBytes: size)
            } catch {
                print("[Receiver] BT write failed for \(transfer.track.videoId): \(error.localizedDescription)")
                wroteSuccessfully = false
            }
        }

        Task { @MainActor in
            self.receivingCount += 1
            defer {
                self.receivingCount = max(0, self.receivingCount - 1)
                if self.receivingCount == 0 {
                    self.savePlaylistsToDisk()
                    self._cachedTrackIds = nil
                    self.refreshAvailable()

                    // Reset sync progress when all transfers done
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        if self.receivingCount == 0 {
                            self.syncingPlaylistName = nil
                            self.syncedTrackCount = 0
                            self.syncTotalCount = 0
                        }
                    }
                }
            }

            if isThumb {
                return
            }

            // Confirm to phone whether file actually wrote (closes the BT-sync drift bug)
            self.sendDownloadResult(videoId: transfer.track.videoId, success: wroteSuccessfully)

            guard wroteSuccessfully else { return }

            // Update sync progress
            self.syncingPlaylistName = transfer.playlistTitle
            self.syncedTrackCount += 1

            if var playlist = self.playlists.first(where: { $0.id == transfer.playlistId }) {
                if !playlist.tracks.contains(where: { $0.videoId == transfer.track.videoId }) {
                    let idx = transfer.indexInPlaylist
                    if idx >= 0 && idx <= playlist.tracks.count {
                        playlist.tracks.insert(transfer.track, at: min(idx, playlist.tracks.count))
                    } else {
                        playlist.tracks.append(transfer.track)
                    }
                }
                self.upsertPlaylistDeferred(playlist)
            } else {
                let newPlaylist = Playlist(
                    id: transfer.playlistId,
                    title: transfer.playlistTitle,
                    thumbnailURL: nil,
                    tracks: [transfer.track]
                )
                self.upsertPlaylistDeferred(newPlaylist)
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncomingMessage(message, replyHandler: nil)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        // Handle syncVerify SYNCHRONOUSLY — replyHandler must be called promptly,
        // dispatching to Task { @MainActor } risks calling it after WCSession invalidates it.
        if let typeStr = message[WatchMessageKey.type.rawValue] as? String,
           typeStr == WatchMessageType.syncVerify.rawValue {
            
            // Send empty reply immediately to satisfy WCSession
            replyHandler([:])
            
            // Inline directory scan using File Enumerator to save memory
            let audioDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Audio", isDirectory: true)
            var ids: [String] = []
            
            if let enumerator = FileManager.default.enumerator(at: audioDir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    guard url.pathExtension == "m4a" else { continue }
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                    if AudioFileGate.isValid(sizeBytes: size) {
                        ids.append(url.deletingPathExtension().lastPathComponent)
                    }
                }
            }
            
            // Send the actual inventory via file transfer (avoids 64KB sendMessage payload limit)
            let tempDir = FileManager.default.temporaryDirectory
            let fileURL = tempDir.appendingPathComponent("inventory_\(UUID().uuidString).json")
            if let data = try? JSONEncoder().encode(ids) {
                try? data.write(to: fileURL)
                session.transferFile(fileURL, metadata: [
                    WatchMessageKey.type.rawValue: WatchMessageType.syncInventory.rawValue
                ])
            }
            return
        }

        // Everything else can go through async handling
        nonisolated(unsafe) let unsafeReply = replyHandler
        let sendableReply: @Sendable ([String: Any]) -> Void = { dict in unsafeReply(dict) }
        handleIncomingMessage(message, replyHandler: sendableReply)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncomingMessage(userInfo)
    }

    /// Clean up the temp inventory_<uuid>.json written for syncVerify once WCSession
    /// has finished sending it — this is the only outgoing transferFile on the Watch side.
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
    }

    private nonisolated func handleIncomingMessage(_ msg: [String: Any], replyHandler: (@Sendable ([String: Any]) -> Void)? = nil) {
        // Extract all values from msg before crossing isolation boundary
        let typeStr = msg[WatchMessageKey.type.rawValue] as? String
        let videoId = msg["videoId"] as? String
        let payloadB64 = msg[WatchMessageKey.payload.rawValue] as? String
        
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { 
                replyHandler?([:])
                return 
            }
            switch type {
            case .deleteTrack:
                if let videoId { self.deleteTrack(videoId: videoId) }
            case .directDownload:
                // Phone sent us a stream URL — download directly over WiFi
                if let b64 = payloadB64,
                   let data = Data(base64Encoded: b64),
                   let payload = try? JSONDecoder().decode(DirectDownloadPayload.self, from: data) {
                    self.handleDirectDownload(payload)
                }
            default:
                break
            }
            replyHandler?([:])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let typeStr = applicationContext[WatchMessageKey.type.rawValue] as? String
        let b64 = applicationContext[WatchMessageKey.payload.rawValue] as? String
        let videoId = applicationContext["videoId"] as? String

        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }

            switch type {
            case .playlistIndex:
                guard let b64, let data = Data(base64Encoded: b64) else { return }
                // Try batch format (array of playlists) first, fall back to single
                if let batchPlaylists = try? JSONDecoder().decode([Playlist].self, from: data) {
                    // Batch upsert: mutate array, save disk ONCE at end (not per playlist).
                    // 30 playlists used to trigger 30 disk writes + 30 directory scans → Watch crash.
                    self.upsertPlaylistsBatch(batchPlaylists)
                    print("[Receiver] Updated \(batchPlaylists.count) playlists from applicationContext")
                } else if let playlist = try? JSONDecoder().decode(Playlist.self, from: data) {
                    self.upsertPlaylist(playlist)
                }
                self.cleanupOrphanedFiles()
            case .deleteTrack:
                if let videoId { self.deleteTrack(videoId: videoId) }
            default:
                break
            }
        }
    }
}
