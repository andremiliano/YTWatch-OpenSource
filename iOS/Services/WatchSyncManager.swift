import Foundation
import WatchConnectivity
import UserNotifications

@MainActor
final class WatchSyncManager: NSObject, ObservableObject {

    static let shared = WatchSyncManager()

    @Published var isWatchReachable = false
    @Published var syncedTrackIds: Set<String> = []
    @Published var transferringTrackIds: Set<String> = []
    @Published var syncedPlaylists: [Playlist] = []
    @Published var pendingSyncCount = 0
    @Published var isVerifying = false
    @Published var lastVerifyResult: VerifyResult?

    struct VerifyResult {
        let phoneThinksSynced: Int
        let actuallyOnWatch: Int
        let missingOnWatch: Int
        let resynced: Int
        let date: Date
    }

    private var session: WCSession?
    private var pendingTransfers: [String: WCSessionFileTransfer] = [:]
    private var pendingSyncQueue: [PendingSyncItem] = []
    private var hadActiveSyncs = false
    /// Tracks waiting for WiFi download result — keyed by videoId, task fires Bluetooth fallback after timeout
    private var wifiTimeoutTasks: [String: Task<Void, Never>] = [:]
    /// VideoIds that failed WiFi download — forces Bluetooth path until next reachability change
    private var wifiFailedVideoIds: Set<String> = []
    /// Max tracks in-flight at once (WiFi + Bluetooth combined). Kept modest so we
    /// never ask the memory-constrained Watch to juggle many downloads at once.
    private static let maxConcurrentSyncTransfers = 5

    struct PendingSyncItem: Codable {
        let videoId: String
        let title: String
        let artist: String
        let album: String?
        let durationSeconds: Int
        let thumbnailURL: String?
        let playlistId: String
        let playlistTitle: String
    }

    override init() {
        super.init()
        loadSyncState()
        loadPendingQueue()
        if WCSession.isSupported() {
            let s = WCSession.default
            s.delegate = self
            s.activate()
            session = s
        }
    }

    // MARK: - Public

    var isAvailable: Bool {
        session?.activationState == .activated && session?.isPaired == true
    }

    func queueTrackForSync(_ track: Track, fileURL: URL, playlistId: String, playlistTitle: String) {
        guard !syncedTrackIds.contains(track.videoId) else { return }
        guard !transferringTrackIds.contains(track.videoId) else { return }

        let item = PendingSyncItem(
            videoId: track.videoId, title: track.title, artist: track.artist,
            album: track.album, durationSeconds: track.durationSeconds,
            thumbnailURL: track.thumbnailURL, playlistId: playlistId, playlistTitle: playlistTitle
        )

        if !pendingSyncQueue.contains(where: { $0.videoId == track.videoId }) {
            pendingSyncQueue.append(item)
            savePendingQueue()
        }

        if isAvailable {
            Task { @MainActor in self.drainPendingQueue() }
        }
    }

    func syncUnsyncedDownloads() {
        let downloaded = AudioDownloader.shared.downloadedTracks
        for (videoId, _) in downloaded {
            guard !syncedTrackIds.contains(videoId) else { continue }
            guard !transferringTrackIds.contains(videoId) else { continue }
            guard !pendingSyncQueue.contains(where: { $0.videoId == videoId }) else { continue }

            if let meta = AudioDownloader.shared.trackMetadata[videoId] {
                let item = PendingSyncItem(
                    videoId: videoId, title: meta.title, artist: meta.artist,
                    album: meta.album, durationSeconds: meta.durationSeconds,
                    thumbnailURL: meta.thumbnailURL,
                    playlistId: "library", playlistTitle: "Downloads"
                )
                pendingSyncQueue.append(item)
            }
        }
        savePendingQueue()
        if isAvailable {
            Task { @MainActor in self.drainPendingQueue() }
        }
    }

    func syncPlaylist(_ playlist: Playlist) {
        guard isAvailable else { return }
        pushPlaylistIndex(playlist)
        
        for (_, track) in playlist.tracks.enumerated() {
            guard !syncedTrackIds.contains(track.videoId) else { continue }
            guard !transferringTrackIds.contains(track.videoId) else { continue }
            guard AudioDownloader.shared.localURL(for: track.videoId) != nil else { continue }
            guard !pendingSyncQueue.contains(where: { $0.videoId == track.videoId }) else { continue }
            
            let item = PendingSyncItem(
                videoId: track.videoId, title: track.title, artist: track.artist,
                album: track.album, durationSeconds: track.durationSeconds,
                thumbnailURL: track.thumbnailURL,
                playlistId: playlist.id, playlistTitle: playlist.title
            )
            pendingSyncQueue.append(item)
        }
        savePendingQueue()
        drainPendingQueue()
    }

    func removeFromWatch(videoId: String) {
        syncedTrackIds.remove(videoId)
        pendingSyncQueue.removeAll { $0.videoId == videoId }
        savePendingQueue()
        saveSyncState()
        guard let session, session.activationState == .activated else { return }
        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.deleteTrack.rawValue,
            "videoId": videoId
        ]
        session.transferUserInfo(msg)
    }

    /// Asks Watch what tracks it actually has, fixes sync state, re-syncs missing tracks.
    func verifySyncAndRepair() {
        guard let session, session.activationState == .activated, session.isReachable else {
            print("[Sync] Watch not reachable for verify")
            return
        }
        guard !isVerifying else { return }
        isVerifying = true

        let msg: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.syncVerify.rawValue
        ]

        session.sendMessage(msg, replyHandler: { _ in
            // The watch will send a file back with the inventory.
            // Setup a safety timeout to clear the spinner if the file never arrives.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s timeout
                guard let self, self.isVerifying else { return }
                self.isVerifying = false
                print("[Sync] Verify timed out waiting for inventory file")
            }
        }, errorHandler: { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isVerifying = false
                print("[Sync] Verify failed: \(error.localizedDescription)")
            }
        })
    }

    /// Max tracks to re-queue per verify call — prevents avalanche
    private static let maxResyncPerVerify = 50

    /// Process Watch inventory response — fix state and re-sync missing tracks (capped).
    /// All operations defensive; failures log but don't crash.
    private func handleSyncInventory(watchTrackIds: [String]) {
        // PHASE 1: Reconcile syncedTrackIds (fast, only Set ops, always safe)
        let watchSet = Set(watchTrackIds)
        let phoneThinksSynced = syncedTrackIds.count
        let falseSynced = syncedTrackIds.subtracting(watchSet)
        let untracked = watchSet.subtracting(syncedTrackIds)
        syncedTrackIds.subtract(falseSynced)
        syncedTrackIds.formUnion(untracked)
        saveSyncState()

        print("[Sync] Reconciled: phone=\(phoneThinksSynced)→\(syncedTrackIds.count), watch=\(watchSet.count), drift=\(falseSynced.count)")

        // PHASE 2: Skip re-queue entirely if nothing missing or queue is already full
        guard !falseSynced.isEmpty else {
            lastVerifyResult = VerifyResult(
                phoneThinksSynced: phoneThinksSynced,
                actuallyOnWatch: watchSet.count,
                missingOnWatch: 0,
                resynced: 0,
                date: Date()
            )
            isVerifying = false
            return
        }

        // Cap re-queue work — don't try to fix more than maxResyncPerVerify at once
        let queueRoom = max(0, Self.maxResyncPerVerify - pendingSyncQueue.count)
        guard queueRoom > 0 else {
            lastVerifyResult = VerifyResult(
                phoneThinksSynced: phoneThinksSynced,
                actuallyOnWatch: watchSet.count,
                missingOnWatch: falseSynced.count,
                resynced: 0,
                date: Date()
            )
            isVerifying = false
            print("[Sync] Verify: queue full, skipping re-queue (will retry on next verify)")
            return
        }

        // PHASE 3: Build re-sync items on MainActor in single pass with safety cap
        var trackPlaylistMap: [String: (playlistId: String, playlistTitle: String, track: Track)] = [:]
        for playlist in syncedPlaylists {
            for track in playlist.tracks {
                trackPlaylistMap[track.videoId] = (playlist.id, playlist.title, track)
            }
        }
        let metadata = AudioDownloader.shared.trackMetadata
        let downloaded = AudioDownloader.shared.downloadedTracks
        let alreadyQueued = Set(pendingSyncQueue.map(\.videoId))
        let transferring = transferringTrackIds

        var newItems: [PendingSyncItem] = []
        for videoId in falseSynced.prefix(queueRoom) {
            guard downloaded[videoId] != nil else { continue }
            guard !alreadyQueued.contains(videoId) else { continue }
            guard !transferring.contains(videoId) else { continue }

            let item: PendingSyncItem
            if let info = trackPlaylistMap[videoId] {
                item = PendingSyncItem(
                    videoId: videoId, title: info.track.title, artist: info.track.artist,
                    album: info.track.album, durationSeconds: info.track.durationSeconds,
                    thumbnailURL: info.track.thumbnailURL,
                    playlistId: info.playlistId, playlistTitle: info.playlistTitle
                )
            } else if let meta = metadata[videoId] {
                item = PendingSyncItem(
                    videoId: videoId, title: meta.title, artist: meta.artist,
                    album: meta.album, durationSeconds: meta.durationSeconds,
                    thumbnailURL: meta.thumbnailURL,
                    playlistId: "library", playlistTitle: "Downloads"
                )
            } else {
                continue
            }
            newItems.append(item)
        }

        // PHASE 4: Apply mutations
        if !newItems.isEmpty {
            pendingSyncQueue.append(contentsOf: newItems)
            savePendingQueue()
        }

        lastVerifyResult = VerifyResult(
            phoneThinksSynced: phoneThinksSynced,
            actuallyOnWatch: watchSet.count,
            missingOnWatch: falseSynced.count,
            resynced: newItems.count,
            date: Date()
        )
        isVerifying = false
        print("[Sync] Verify done: queued \(newItems.count) re-syncs (cap=\(Self.maxResyncPerVerify), drift=\(falseSynced.count))")

        // Trigger one drain to start the batch — drain itself caps at maxConcurrentSyncTransfers (10)
        if !newItems.isEmpty {
            drainPendingQueue()
        }
    }

    // MARK: - Private

    private func drainPendingQueue() {
        guard isAvailable else { return }

        // Clean already-synced items from queue (single source of truth)
        let beforeCount = pendingSyncQueue.count
        pendingSyncQueue.removeAll { syncedTrackIds.contains($0.videoId) }
        if pendingSyncQueue.count != beforeCount { savePendingQueue() }

        // Batch limit — don't overwhelm Watch with 200+ concurrent transfers
        let slotsAvailable = Self.maxConcurrentSyncTransfers - transferringTrackIds.count
        guard slotsAvailable > 0 else { return }

        // Build transfer list — items STAY in queue until confirmed synced
        var toSync: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []

        for (i, item) in pendingSyncQueue.enumerated() {
            guard toSync.count < slotsAvailable else { break }
            guard !transferringTrackIds.contains(item.videoId) else { continue }
            guard let localURL = AudioDownloader.shared.localURL(for: item.videoId) else { continue }
            let track = Track(
                id: item.videoId, videoId: item.videoId, title: item.title,
                artist: item.artist, album: item.album,
                durationSeconds: item.durationSeconds, thumbnailURL: item.thumbnailURL
            )
            toSync.append((track, localURL, item.playlistId, item.playlistTitle, i))
        }

        guard !toSync.isEmpty else { return }

        for item in toSync {
            transferringTrackIds.insert(item.track.videoId)
        }
        hadActiveSyncs = true
        let pending = pendingSyncQueue.count - toSync.count
        if pending > 0 { print("[Sync] Batch \(toSync.count) tracks (\(pending) still queued)") }

        // Split: WiFi-failed tracks always go Bluetooth; rest try WiFi if Watch reachable
        let watchReachable = session?.isReachable == true
        if watchReachable {
            var wifiItems: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []
            var btItems: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []
            for item in toSync {
                if wifiFailedVideoIds.contains(item.track.videoId) {
                    btItems.append(item)
                } else {
                    wifiItems.append(item)
                }
            }
            if !wifiItems.isEmpty { syncViaDirectDownload(wifiItems) }
            if !btItems.isEmpty { syncViaTransferFile(btItems) }
        } else {
            syncViaTransferFile(toSync)
        }
    }

    /// Fast path: resolve stream URLs and tell Watch to download directly over WiFi.
    /// Falls back to transferFile for any track that fails URL resolution or sendMessage.
    /// Each sent track gets a 120s timeout — if Watch doesn't respond, falls back to Bluetooth.
    private func syncViaDirectDownload(_ items: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)]) {
        guard let session else {
            syncViaTransferFile(items)
            return
        }

        Task {
            var fallback: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)] = []

            // Resolve URLs with bounded concurrency (avoid rate limiting)
            await withTaskGroup(of: (Int, URL?).self) { group in
                var pending = items.enumerated().makeIterator()

                // Launch first batch (max 3 concurrent)
                for _ in 0..<3 {
                    guard let (idx, item) = pending.next() else { break }
                    group.addTask {
                        let url = try? await YTMusicClient.shared.fetchAudioStreamURL(videoId: item.track.videoId)
                        return (idx, url)
                    }
                }

                for await (idx, streamURL) in group {
                    let item = items[idx]
                    if let streamURL {
                        let request = AudioDownloader.buildStreamRequest(streamURL: streamURL)
                        var headers: [String: String] = [:]
                        for (key, value) in request.allHTTPHeaderFields ?? [:] {
                            headers[key] = value
                        }

                        let payload = DirectDownloadPayload(
                            track: item.track,
                            playlistId: item.playlistId,
                            playlistTitle: item.playlistTitle,
                            indexInPlaylist: item.index,
                            streamURL: streamURL.absoluteString,
                            headers: headers,
                            thumbnailDownloadURL: item.track.thumbnailURL
                        )

                        if let data = try? JSONEncoder().encode(payload) {
                            let msg: [String: Any] = [
                                WatchMessageKey.type.rawValue: WatchMessageType.directDownload.rawValue,
                                WatchMessageKey.payload.rawValue: data.base64EncodedString()
                            ]
                            let videoId = item.track.videoId
                            session.sendMessage(msg, replyHandler: nil) { [weak self] error in
                                // sendMessage failed → mark WiFi-failed, remove from transferring, re-drain picks up via Bluetooth
                                print("[Sync] sendMessage failed for \(videoId): \(error.localizedDescription)")
                                Task { @MainActor in
                                    guard let self else { return }
                                    self.cancelWifiTimeout(for: videoId)
                                    self.wifiFailedVideoIds.insert(videoId)
                                    self.transferringTrackIds.remove(videoId)
                                    self.drainPendingQueue()
                                }
                            }
                            // Start timeout — if Watch doesn't respond in 120s, fall back to Bluetooth
                            startWifiTimeout(for: videoId)
                            print("[Sync] → WiFi download \(item.track.title)")
                        } else {
                            fallback.append(item)
                        }
                    } else {
                        // URL resolution failed — fall back to Bluetooth transfer
                        fallback.append(item)
                    }

                    // Launch next item
                    if let (nextIdx, nextItem) = pending.next() {
                        group.addTask {
                            let url = try? await YTMusicClient.shared.fetchAudioStreamURL(videoId: nextItem.track.videoId)
                            return (nextIdx, url)
                        }
                    }
                }
            }

            // Transfer any URL-resolution failures via Bluetooth
            if !fallback.isEmpty {
                print("[Sync] Falling back to Bluetooth for \(fallback.count) tracks")
                syncViaTransferFile(fallback)
            }
        }
    }

    // MARK: - WiFi Download Timeout

    private func startWifiTimeout(for videoId: String) {
        wifiTimeoutTasks[videoId]?.cancel()
        wifiTimeoutTasks[videoId] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // Still waiting? → fall back to Bluetooth
            guard self.transferringTrackIds.contains(videoId),
                  !self.syncedTrackIds.contains(videoId) else { return }
            print("[Sync] WiFi download timeout: \(videoId) — falling back to Bluetooth")
            self.wifiFailedVideoIds.insert(videoId)
            self.transferringTrackIds.remove(videoId)
            self.drainPendingQueue()
        }
    }

    private func cancelWifiTimeout(for videoId: String) {
        wifiTimeoutTasks[videoId]?.cancel()
        wifiTimeoutTasks.removeValue(forKey: videoId)
    }

    private func cancelAllWifiTimeouts() {
        for (_, task) in wifiTimeoutTasks { task.cancel() }
        wifiTimeoutTasks.removeAll()
    }

    /// Slow path: transfer files over Bluetooth via WCSession.transferFile
    private func syncViaTransferFile(_ items: [(track: Track, url: URL, playlistId: String, playlistTitle: String, index: Int)]) {
        Task.detached {
            // Download thumbnails first
            await withTaskGroup(of: Void.self) { group in
                for item in items {
                    group.addTask {
                        if let thumbStr = item.track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
                            await Self.downloadThumbnailBackground(from: thumbURL, videoId: item.track.videoId)
                        }
                    }
                }
            }
            await MainActor.run { [items] in
                guard let session = self.session else { return }
                for item in items {
                    let meta = TrackTransferMetadata(track: item.track, playlistId: item.playlistId, playlistTitle: item.playlistTitle, indexInPlaylist: item.index)
                    guard let metaData = try? JSONEncoder().encode(meta),
                          let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
                        self.transferringTrackIds.remove(item.track.videoId)
                        continue
                    }
                    let transfer = session.transferFile(item.url, metadata: metaDict)
                    self.pendingTransfers[item.track.videoId] = transfer

                    let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(item.track.videoId).jpg")
                    if FileManager.default.fileExists(atPath: thumbDest.path) {
                        var thumbMeta = metaDict
                        thumbMeta["isThumbnail"] = true
                        session.transferFile(thumbDest, metadata: thumbMeta)
                    }
                }
            }
        }
    }

    private func savePendingQueue() {
        pendingSyncCount = pendingSyncQueue.count
        if let data = try? JSONEncoder().encode(pendingSyncQueue) {
            UserDefaults.standard.set(data, forKey: "pendingSyncQueue")
        }
    }

    private func loadPendingQueue() {
        if let data = UserDefaults.standard.data(forKey: "pendingSyncQueue"),
           let items = try? JSONDecoder().decode([PendingSyncItem].self, from: data) {
            pendingSyncQueue = items
            pendingSyncCount = items.count
        }
    }

    private func queueTransfers(_ items: [(track: Track, url: URL, index: Int)], playlistId: String, playlistTitle: String) {
        guard let session else { return }
        for item in items {
            let meta = TrackTransferMetadata(track: item.track, playlistId: playlistId, playlistTitle: playlistTitle, indexInPlaylist: item.index)
            guard let metaData = try? JSONEncoder().encode(meta),
                  let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
                transferringTrackIds.remove(item.track.videoId)
                continue
            }

            let transfer = session.transferFile(item.url, metadata: metaDict)
            pendingTransfers[item.track.videoId] = transfer

            let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(item.track.videoId).jpg")
            if FileManager.default.fileExists(atPath: thumbDest.path) {
                var thumbMeta = metaDict
                thumbMeta["isThumbnail"] = true
                session.transferFile(thumbDest, metadata: thumbMeta)
            }
        }
    }

    private func transferTrack(_ track: Track, from url: URL, playlistId: String, playlistTitle: String, index: Int) async {
        guard let session else { return }
        transferringTrackIds.insert(track.videoId)
        hadActiveSyncs = true

        if let thumbStr = track.thumbnailURL, let thumbURL = URL(string: thumbStr) {
            await Self.downloadThumbnailBackground(from: thumbURL, videoId: track.videoId)
        }

        let meta = TrackTransferMetadata(track: track, playlistId: playlistId, playlistTitle: playlistTitle, indexInPlaylist: index)
        guard let metaData = try? JSONEncoder().encode(meta),
              let metaDict = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] else {
            transferringTrackIds.remove(track.videoId)
            return
        }

        let transfer = session.transferFile(url, metadata: metaDict)
        pendingTransfers[track.videoId] = transfer

        let thumbDest = Self.thumbnailCacheDir.appendingPathComponent("\(track.videoId).jpg")
        if FileManager.default.fileExists(atPath: thumbDest.path) {
            var thumbMeta = metaDict
            thumbMeta["isThumbnail"] = true
            session.transferFile(thumbDest, metadata: thumbMeta)
        }
    }

    nonisolated private static var thumbnailCacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SyncThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private nonisolated static func downloadThumbnailBackground(from url: URL, videoId: String) async {
        let dest = thumbnailCacheDir.appendingPathComponent("\(videoId).jpg")
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              !data.isEmpty else { return }
        try? data.write(to: dest)
    }

    private func pushPlaylistIndex(_ playlist: Playlist) {
        // Track synced playlists locally
        if let idx = syncedPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            syncedPlaylists[idx] = playlist
        } else {
            syncedPlaylists.append(playlist)
        }
        saveSyncState()
        pushAllPlaylistIndexes()
    }

    private func pushAllPlaylistIndexes() {
        guard let session, session.activationState == .activated else { return }
        // Send ALL playlist indexes in one applicationContext (single slot — must batch)
        guard let data = try? JSONEncoder().encode(syncedPlaylists) else { return }
        let context: [String: Any] = [
            WatchMessageKey.type.rawValue: WatchMessageType.playlistIndex.rawValue,
            WatchMessageKey.payload.rawValue: data.base64EncodedString()
        ]
        try? session.updateApplicationContext(context)
    }

    /// Handle authoritative confirmation from Watch about a track (WiFi OR Bluetooth path).
    /// This is the SINGLE source of truth for syncedTrackIds — Watch tells us what it has.
    private func handleDirectDownloadResult(videoId: String, success: Bool) {
        cancelWifiTimeout(for: videoId)
        transferringTrackIds.remove(videoId)

        if success {
            // Watch confirmed file written successfully — mark as synced
            syncedTrackIds.insert(videoId)
            pendingSyncQueue.removeAll { $0.videoId == videoId }
            savePendingQueue()
            saveSyncState()
            print("[Sync] ✓ \(videoId) confirmed by Watch (\(syncedTrackIds.count) total)")
            checkSyncCompletion()
            drainPendingQueue()
        } else {
            // Watch FAILED to write file — CORRECT phone state and re-queue
            // (this is critical: closes the BT premature-mark drift bug)
            if syncedTrackIds.remove(videoId) != nil {
                saveSyncState()
                print("[Sync] ✗ Corrected: \(videoId) was marked synced but Watch failed to write")
            } else {
                print("[Sync] ✗ \(videoId) failed on Watch")
            }
            wifiFailedVideoIds.insert(videoId) // force Bluetooth retry path
            // Re-queue if not already in pendingSyncQueue
            if !pendingSyncQueue.contains(where: { $0.videoId == videoId }) {
                reEnqueueForRetry(videoId: videoId)
            }
            drainPendingQueue()
        }
    }

    /// Re-enqueue a track for sync (used on Watch-reported failure).
    private func reEnqueueForRetry(videoId: String) {
        // Build PendingSyncItem from known metadata
        var pid = "library"
        var ptitle = "Downloads"
        var trackData: (title: String, artist: String, album: String?, duration: Int, thumb: String?)?

        for playlist in syncedPlaylists {
            if let t = playlist.tracks.first(where: { $0.videoId == videoId }) {
                pid = playlist.id
                ptitle = playlist.title
                trackData = (t.title, t.artist, t.album, t.durationSeconds, t.thumbnailURL)
                break
            }
        }
        if trackData == nil, let m = AudioDownloader.shared.trackMetadata[videoId] {
            trackData = (m.title, m.artist, m.album, m.durationSeconds, m.thumbnailURL)
        }
        guard let t = trackData else {
            print("[Sync] Cannot re-enqueue \(videoId): no metadata")
            return
        }
        pendingSyncQueue.append(PendingSyncItem(
            videoId: videoId, title: t.title, artist: t.artist,
            album: t.album, durationSeconds: t.duration,
            thumbnailURL: t.thumb, playlistId: pid, playlistTitle: ptitle
        ))
        savePendingQueue()
    }

    private func checkSyncCompletion() {
        guard hadActiveSyncs else { return }
        guard transferringTrackIds.isEmpty && pendingSyncQueue.isEmpty else { return }
        hadActiveSyncs = false
        let count = syncedTrackIds.count
        let content = UNMutableNotificationContent()
        content.title = "Watch Sync Complete"
        content.body = "\(count) tracks synced to Apple Watch"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "syncComplete", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func saveSyncState() {
        let ids = Array(syncedTrackIds)
        UserDefaults.standard.set(ids, forKey: "syncedTrackIds")

        if let data = try? JSONEncoder().encode(syncedPlaylists) {
            UserDefaults.standard.set(data, forKey: "syncedPlaylists")
        }
    }

    private func loadSyncState() {
        if let ids = UserDefaults.standard.array(forKey: "syncedTrackIds") as? [String] {
            syncedTrackIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "syncedPlaylists"),
           let playlists = try? JSONDecoder().decode([Playlist].self, from: data) {
            syncedPlaylists = playlists
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchSyncManager: WCSessionDelegate {

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        var outstandingVideoIds: [String] = []
        for transfer in session.outstandingFileTransfers {
            guard let meta = transfer.file.metadata,
                  (meta["isThumbnail"] as? Bool) != true,
                  let metaData = try? JSONSerialization.data(withJSONObject: meta),
                  let decoded = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) else { continue }
            outstandingVideoIds.append(decoded.track.videoId)
        }
        Task { @MainActor in
            self.isWatchReachable = reachable
            for videoId in outstandingVideoIds {
                self.transferringTrackIds.insert(videoId)
            }
            // Drain existing queue only — do NOT auto-add new items or push playlists on activation.
            // Those operations belong in explicit user actions (sync playlist / verify) to avoid
            // crash avalanches when state is already large.
            self.drainPendingQueue()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            self.isWatchReachable = reachable
            if reachable {
                // Fresh connection — clear WiFi-failed so tracks can try WiFi again
                self.wifiFailedVideoIds.removeAll()
                // NO auto-verify — user must explicitly tap Verify & Re-sync.
                // Auto-firing on every reachability caused crash loops on bad state.
                self.drainPendingQueue()
            } else {
                // Watch went unreachable — cancel pending WiFi timeouts
                self.cancelAllWifiTimeouts()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        if let typeStr = file.metadata?[WatchMessageKey.type.rawValue] as? String,
           typeStr == WatchMessageType.syncInventory.rawValue {
            if let data = try? Data(contentsOf: file.fileURL),
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                Task { @MainActor in
                    self.handleSyncInventory(watchTrackIds: ids)
                }
            }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        // Extract videoId from transfer metadata — survives app relaunch unlike in-memory dict
        let meta = fileTransfer.file.metadata
        let isThumbnail = (meta?["isThumbnail"] as? Bool) == true
        var videoId: String?
        if let meta, let metaData = try? JSONSerialization.data(withJSONObject: meta),
           let decoded = try? JSONDecoder().decode(TrackTransferMetadata.self, from: metaData) {
            videoId = decoded.track.videoId
        }
        let succeeded = error == nil
        let errorMsg = error?.localizedDescription

        Task { @MainActor in
            guard let videoId, !isThumbnail else { return }
            self.pendingTransfers.removeValue(forKey: videoId)

            if succeeded {
                // iPhone finished sending. TENTATIVELY mark synced — Watch will confirm via downloadResult.
                // If Watch fails to write, handleDirectDownloadResult removes from syncedTrackIds (correction).
                self.transferringTrackIds.remove(videoId)
                self.syncedTrackIds.insert(videoId)
                self.pendingSyncQueue.removeAll { $0.videoId == videoId }
                self.savePendingQueue()
                self.saveSyncState()
                print("[Sync] → BT \(videoId) sent (\(self.syncedTrackIds.count) tentative)")
                self.checkSyncCompletion()
                self.drainPendingQueue()
            } else {
                // Transfer failed at WCSession level → file never reached Watch.
                // Keep in pendingSyncQueue, retry on next drain.
                self.transferringTrackIds.remove(videoId)
                print("[Sync] ✗ BT \(videoId): \(errorMsg ?? "unknown") — will retry")
                self.drainPendingQueue()
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let typeStr = message[WatchMessageKey.type.rawValue] as? String
        let trackIds = message["trackIds"] as? [String]
        let videoIds = message["videoIds"] as? [String]
        let videoId = message["videoId"] as? String
        let success = message["success"] as? Bool
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            switch type {
            case .syncInventory:
                self.handleSyncInventory(watchTrackIds: trackIds ?? [])
            case .downloadResult:
                if let videoId { self.handleDirectDownloadResult(videoId: videoId, success: success ?? false) }
            case .requestRedownload:
                if let videoIds { self.handleRedownloadRequest(videoIds: videoIds) }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let typeStr = userInfo[WatchMessageKey.type.rawValue] as? String
        let videoIds = userInfo["videoIds"] as? [String]
        let videoId = userInfo["videoId"] as? String
        let success = userInfo["success"] as? Bool
        Task { @MainActor in
            guard let typeStr, let type = WatchMessageType(rawValue: typeStr) else { return }
            switch type {
            case .downloadResult:
                if let videoId { self.handleDirectDownloadResult(videoId: videoId, success: success ?? false) }
            case .requestRedownload:
                if let videoIds { self.handleRedownloadRequest(videoIds: videoIds) }
            default:
                break
            }
        }
    }

    /// Watch reported these tracks as missing/corrupt — clear their synced state and re-send.
    private func handleRedownloadRequest(videoIds: [String]) {
        guard !videoIds.isEmpty else { return }
        print("[Sync] Watch requested re-download of \(videoIds.count) tracks")
        var requeued = 0
        for videoId in videoIds {
            // Only re-send tracks the phone still has locally
            guard AudioDownloader.shared.localURL(for: videoId) != nil else { continue }
            syncedTrackIds.remove(videoId)
            wifiFailedVideoIds.remove(videoId)
            if !pendingSyncQueue.contains(where: { $0.videoId == videoId }) {
                reEnqueueForRetry(videoId: videoId)
                requeued += 1
            }
        }
        saveSyncState()
        if requeued > 0 { drainPendingQueue() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
