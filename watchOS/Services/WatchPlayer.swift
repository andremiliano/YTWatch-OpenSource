//
//  WatchPlayer.swift
//  YTWatch
//
//  Core playback engine for the Apple Watch.
//
//  Architecture Notes:
//  - Uses a single `AVPlayer` instance across the entire lifecycle to prevent Jetsam memory
//    crashes caused by allocating a new player for every track.
//  - Handles padded audio containers gracefully (common with scraped audio streams) using
//    a custom stall detection timer.
//  - Fully integrates with `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` for lock screen controls.
//

import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import WatchKit
import ImageIO

enum RepeatMode: String {
    case none, one, all

    var next: RepeatMode {
        switch self {
        case .none: return .all
        case .all:  return .one
        case .one:  return .none
        }
    }

    var sfSymbol: String {
        switch self {
        case .none, .all: return "repeat"
        case .one:        return "repeat.1"
        }
    }
}

struct RecentPlay: Codable, Identifiable {
    var id: String { trackVideoId }
    let trackVideoId: String
    let trackTitle: String
    let trackArtist: String
    let trackDurationSeconds: Int
    let playlistId: String
    let playlistTitle: String
    let date: Date

    init(track: Track, playlistId: String, playlistTitle: String, date: Date) {
        self.trackVideoId = track.videoId
        self.trackTitle = track.title
        self.trackArtist = track.artist
        self.trackDurationSeconds = track.durationSeconds
        self.playlistId = playlistId
        self.playlistTitle = playlistTitle
        self.date = date
    }

    var asTrack: Track {
        Track(id: trackVideoId, videoId: trackVideoId, title: trackTitle, artist: trackArtist, durationSeconds: trackDurationSeconds)
    }
}

@MainActor
final class WatchPlayer: ObservableObject {

    static let shared = WatchPlayer()

    @Published var currentTrack: Track?
    @Published var currentPlaylist: Playlist?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var error: String?
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .none
    @Published var currentVolume: Float = 0.5
    /// When a playlist ends, keep playing an endless shuffle of the whole library
    /// instead of stopping.
    @Published var autoPlaySimilar: Bool = (UserDefaults.standard.object(forKey: "autoPlaySimilar") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(autoPlaySimilar, forKey: "autoPlaySimilar") }
    }
    /// Bumped whenever the play queue is edited, so views re-read `upNextTracks`.
    @Published private(set) var queueRevision = 0

    // Sleep timer
    @Published var sleepTimerRemaining: TimeInterval? = nil
    private var sleepTimer: Timer?
    private var sleepTimerTarget: Date? // absolute target time — survives background

    // Track change toast
    @Published var trackChangeToast: Track? = nil

    // Recently played tracking
    @Published var recentlyPlayed: [RecentPlay] = []
    private static let maxRecentPlays = 50

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var currentIndex = 0

    /// Tested, crash-proof queue logic (see PlaybackQueue + PlaybackCoreTests).
    private var queue = PlaybackQueue()
    private var rng = SystemRandomNumberGenerator()
    private var wasPlayingBeforeInterruption = false
    private var timeObserverTick = 0
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    // Incremented each time we start a new track — guards against stale async callbacks
    private var playbackGeneration: Int = 0
    private var sessionActivated = false
    // Stall detection — catches tracks where container duration > actual audio
    private var stallDetector = StallDetector()
    /// Catches playback that silently stopped while we still intend to play (see type).
    private var playbackWatchdog = PlaybackWatchdog()
    private var stallTimer: Timer?
    private var failObserver: NSObjectProtocol?
    /// Set when Bluetooth audio disappears mid-playback, so playback can resume on its
    /// own when the headphones reconnect — they drop out routinely during a run.
    private var routeLossPauseDate: Date?
    private static let routeResumeWindow: TimeInterval = 300
    /// Last moment audio was confirmed flowing; lets a route-loss that arrives just after
    /// an interruption already paused us still count as "was playing".
    private var lastAudibleAt: Date?
    /// The known duration from track metadata (API-sourced, accurate).
    /// Separate from `duration` which may be overwritten by AVPlayer container duration.
    private var knownTrackDuration: Double = 0
    /// Guards against double-advance — a finishing track can trigger the end
    /// notification, duration detection, and stall detection all at once.
    private var finishedGeneration: Int = -1
    /// Bounded skip counter — prevents infinite recursion/crash when nothing is playable.
    private var consecutiveFailures: Int = 0
    private static let maxConsecutiveFailures = 40

    // MARK: - Session setup

    func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        } catch {
            self.error = "Audio session: \(error.localizedDescription)"
        }
        setupRemoteControls()
        setupInterruptionHandling()
        setupRouteChangeHandling()
        loadRecentlyPlayed()
        restoreLastPlayed()
    }

    private var activationRetryCount = 0
    private static let maxActivationRetries = 3

    private func activateSessionAndPlay(url: URL, generation: Int) {
        if sessionActivated {
            activationRetryCount = 0
            beginPlayback(url: url, generation: generation)
            return
        }
        let session = AVAudioSession.sharedInstance()
        session.activate(options: []) { [weak self] success, activationError in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                guard success else {
                    if self.activationRetryCount < Self.maxActivationRetries {
                        self.activationRetryCount += 1
                        let delay = UInt64(self.activationRetryCount) * 500_000_000
                        print("[Player] Activation retry \(self.activationRetryCount)/\(Self.maxActivationRetries)")
                        try? await Task.sleep(nanoseconds: delay)
                        guard self.playbackGeneration == generation else { return }
                        self.activateSessionAndPlay(url: url, generation: generation)
                    } else {
                        self.activationRetryCount = 0
                        self.error = "Audio activation failed: \(activationError?.localizedDescription ?? "unknown")"
                        // playTrack no longer empties the player up front (so track handoffs
                        // stay gapless), so the previous item may still be loaded here. Clear
                        // it, or "play" would resume the old song under the new one's title.
                        self.tearDownPlayer()
                        self.isPlaying = false
                    }
                    return
                }
                self.activationRetryCount = 0
                self.sessionActivated = true
                self.beginPlayback(url: url, generation: generation)
            }
        }
    }

    func setVolume(_ vol: Float) {
        let clamped = max(0, min(1, vol))
        currentVolume = clamped
        player?.volume = clamped
    }

    // MARK: - Playback control

    func load(playlist: Playlist, startAt index: Int = 0) {
        currentPlaylist = playlist
        consecutiveFailures = 0
        playbackWatchdog.userTookControl()
        buildQueue(startingAt: index)
        guard let idx = queue.currentIndex else {
            error = "No downloaded tracks in \(playlist.title)"
            stopPlayback()
            return
        }
        currentIndex = idx
        playTrack(at: currentIndex)
    }

    /// Shuffle every downloaded track across ALL albums/playlists and play them in
    /// random order. Loops forever (repeat all) so it keeps going through everything.
    func playAllShuffled() {
        startLibraryShuffle(id: "__all_songs__", title: "Shuffle All", userInitiated: true)
    }

    /// Endless library shuffle used to auto-continue when a playlist ends.
    private func beginAutoMix() {
        startLibraryShuffle(id: "__auto_mix__", title: "Auto Mix", userInitiated: false)
    }

    /// - Parameter userInitiated: false for the automatic continuation. That path must not
    ///   reset the failure counters — it's reached from the skip loop itself, and resetting
    ///   there would let a library of unplayable files cycle forever instead of stopping.
    private func startLibraryShuffle(id: String, title: String, userInitiated: Bool) {
        // Gather every available track across all playlists, deduped by videoId
        var seen = Set<String>()
        var tracks: [Track] = []
        for pl in WatchFileReceiver.shared.availablePlaylists {
            for t in pl.tracks where seen.insert(t.videoId).inserted {
                tracks.append(t)
            }
        }
        guard !tracks.isEmpty else {
            error = "No downloaded tracks"
            stopPlayback()
            return
        }

        let synthetic = Playlist(id: id, title: title, thumbnailURL: nil, tracks: tracks)
        isShuffled = true
        repeatMode = .all
        currentPlaylist = synthetic
        if userInitiated {
            consecutiveFailures = 0
            playbackWatchdog.userTookControl()
        }
        queueRevision += 1
        buildQueue(startingAt: Int.random(in: 0..<tracks.count))
        guard let idx = queue.currentIndex else { stopPlayback(); return }
        if userInitiated { haptic(.start) }
        currentIndex = idx
        playTrack(at: currentIndex)
    }

    // MARK: - Queue Editing

    /// Remove a track from the Up Next queue (only affects not-yet-played items).
    func removeFromQueue(videoId: String) {
        guard let playlist = currentPlaylist,
              let trackIdx = playlist.tracks.firstIndex(where: { $0.videoId == videoId }) else { return }
        queue.remove(trackIndex: trackIdx)
        queueRevision += 1
        haptic(.click)
    }

    /// Move a queued track to play immediately after the current one.
    func playTrackNext(videoId: String) {
        guard let playlist = currentPlaylist,
              let trackIdx = playlist.tracks.firstIndex(where: { $0.videoId == videoId }) else { return }
        queue.moveToNext(trackIndex: trackIdx)
        queueRevision += 1
        haptic(.click)
    }

    func play() {
        routeLossPauseDate = nil
        playbackWatchdog.userTookControl()
        // A finished item is still loaded, parked at its end, so "play" on it would be
        // silent — move on to the next track instead.
        if player?.currentItem != nil, finishedGeneration == playbackGeneration {
            advanceQueue(forward: true)
            return
        }
        guard player?.currentItem != nil else {
            // No item loaded — (re)load the current track
            if let track = currentTrack,
               let url = WatchFileReceiver.shared.audioURL(for: track.videoId) {
                knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
                if duration <= 0 { duration = knownTrackDuration }
                stallDetector.reset()
                playbackGeneration += 1
                activateSessionAndPlay(url: url, generation: playbackGeneration)
            }
            return
        }
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    func pause() {
        routeLossPauseDate = nil
        playbackWatchdog.userTookControl()
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func next() {
        playbackWatchdog.userTookControl()
        advanceQueue(forward: true)
    }

    func previous() {
        playbackWatchdog.userTookControl()
        if currentTime > 3 {
            seek(to: 0)
        } else {
            advanceQueue(forward: false)
        }
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 1000)
        player?.seek(to: cmTime)
        currentTime = time
        updateNowPlaying()
    }

    func toggleShuffle() {
        isShuffled.toggle()
        haptic(.click)
        guard currentPlaylist != nil else { return }
        // Rebuild around the current track — buildQueue filters to available tracks
        // and keeps the current song at the front, so shuffle never gets "stuck".
        buildQueue(startingAt: currentIndex)
    }

    func toggleRepeat() {
        repeatMode = repeatMode.next
        haptic(.click)
    }

    // MARK: - Up Next

    var upNextTracks: [Track] {
        guard let playlist = currentPlaylist else { return [] }
        _ = queueRevision // observe edits so the UI refreshes
        return queue.upNext(limit: 20).compactMap { idx -> Track? in
            guard idx >= 0, idx < playlist.tracks.count else { return nil }
            return playlist.tracks[idx]
        }
    }

    // MARK: - Sleep Timer

    func startSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let target = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerTarget = target
        sleepTimerRemaining = TimeInterval(minutes * 60)
        haptic(.start)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let target = self.sleepTimerTarget else { return }
                let remaining = target.timeIntervalSinceNow
                if remaining <= 0 {
                    self.cancelSleepTimer()
                    self.pause()
                    self.haptic(.stop)
                } else {
                    self.sleepTimerRemaining = remaining
                }
            }
        }
    }

    /// Sleep at end of current track
    func startSleepTimerEndOfTrack() {
        cancelSleepTimer()
        sleepTimerRemaining = -1 // sentinel: end-of-track mode
        haptic(.start)
    }

    func cancelSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerRemaining = nil
        sleepTimerTarget = nil
    }

    /// Re-sync timer on app wake — recalculates remaining from absolute target
    func refreshSleepTimer() {
        guard let target = sleepTimerTarget else { return }
        let remaining = target.timeIntervalSinceNow
        if remaining <= 0 {
            cancelSleepTimer()
            pause()
            haptic(.stop)
        } else {
            sleepTimerRemaining = remaining
        }
    }

    var isSleepTimerEndOfTrack: Bool { sleepTimerRemaining == -1 }

    // MARK: - Recently Played

    func loadRecentlyPlayed() {
        guard let data = UserDefaults.standard.data(forKey: "recentlyPlayed"),
              let decoded = try? JSONDecoder().decode([RecentPlay].self, from: data) else { return }
        recentlyPlayed = decoded
    }

    private func recordPlay(_ track: Track, playlist: Playlist) {
        recentlyPlayed.removeAll { $0.trackVideoId == track.videoId }
        let entry = RecentPlay(track: track, playlistId: playlist.id, playlistTitle: playlist.title, date: Date())
        recentlyPlayed.insert(entry, at: 0)
        if recentlyPlayed.count > Self.maxRecentPlays {
            recentlyPlayed = Array(recentlyPlayed.prefix(Self.maxRecentPlays))
        }
        if let data = try? JSONEncoder().encode(recentlyPlayed) {
            UserDefaults.standard.set(data, forKey: "recentlyPlayed")
        }
    }

    // MARK: - Haptics

    private func haptic(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }

    // MARK: - Private

    private func availableIndices(in playlist: Playlist) -> [Int] {
        let availableIds = WatchFileReceiver.shared.cachedOrFreshTrackIds()
        return playlist.tracks.indices.filter {
            availableIds.contains(playlist.tracks[$0].videoId)
        }
    }

    private func buildQueue(startingAt index: Int) {
        let avail = currentPlaylist.map { availableIndices(in: $0) } ?? []
        queue.build(availableIndices: avail, startAt: index, shuffled: isShuffled, using: &rng)
    }

    private func advanceQueue(forward: Bool) {
        CrashBreadcrumb.mark(.advancingQueue)
        guard let playlist = currentPlaylist else { return }
        let avail = availableIndices(in: playlist)
        let result = queue.advance(
            forward: forward,
            repeatAll: repeatMode == .all,
            availableIndices: avail,
            using: &rng
        )
        switch result {
        case .play(let idx):
            currentIndex = idx
            playTrack(at: idx)
        case .endReached:
            // End of queue in .none mode. Auto-continue with an endless library
            // shuffle if enabled; otherwise move to the next album, then stop.
            if autoPlaySimilar && currentPlaylist?.id != "__auto_mix__" {
                beginAutoMix()
            } else {
                stopPlayback()
            }
        case .atStart:
            break // already at the first track
        case .empty:
            if autoPlaySimilar {
                beginAutoMix()
            } else {
                stopPlayback()
            }
        }
    }

    private func playTrack(at index: Int) {
        guard let playlist = currentPlaylist,
              index >= 0, index < playlist.tracks.count else { return }

        let track = playlist.tracks[index]
        guard let url = WatchFileReceiver.shared.audioURL(for: track.videoId) else {
            // The queue only offers tracks the availability cache says are on disk, so
            // reaching here means that cache is stale. Drop it, or every subsequent
            // advance keeps picking missing tracks until the skip guard stops playback.
            WatchFileReceiver.shared.invalidateAvailabilityCache()
            handleUnplayable(track: track, reason: "not downloaded")
            return
        }

        // Verify file is not empty/truncated before handing it to AVPlayer.
        // A truncated m4a is the main way a bad file can destabilize playback.
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard AudioFileGate.isValid(sizeBytes: fileSize) else {
            // Too small to be real audio — delete it and ask the phone to re-send.
            WatchFileReceiver.shared.deleteCorruptAudioFile(videoId: track.videoId)
            WatchFileReceiver.shared.requestRedownload(videoIds: [track.videoId])
            handleUnplayable(track: track, reason: "file truncated (\(fileSize)b)")
            return
        }

        // Do NOT pause or empty the player between tracks. With the screen off (e.g. on a
        // run) watchOS may suspend a background-audio app as soon as its audio stops, and
        // the async readiness callback that used to start the next track then never runs —
        // playback silently ends a few songs in. beginPlayback swaps the item and re-issues
        // play() in the same turn, so the player never goes idle across the handoff.
        removeItemObservers()
        stopStallTimer()

        playbackGeneration += 1
        let gen = playbackGeneration
        playbackWatchdog.trackStarted()

        CrashBreadcrumb.mark(.startingTrack(track.title))
        currentIndex = index
        currentTrack = track
        error = nil
        knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
        duration = knownTrackDuration
        currentTime = 0
        stallDetector.reset()

        // Haptic + toast on track change
        haptic(.click)
        trackChangeToast = track
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self.trackChangeToast?.videoId == track.videoId {
                self.trackChangeToast = nil
            }
        }

        // Record play
        if let playlist = currentPlaylist {
            recordPlay(track, playlist: playlist)
        }

        // Update Now Playing immediately so it shows even before audio starts
        updateNowPlaying()

        activateSessionAndPlay(url: url, generation: gen)
    }

    /// Called when a track can't be played. Bounded so it never infinitely
    /// recurses or crashes when many/all tracks are missing.
    private func handleUnplayable(track: Track, reason: String) {
        consecutiveFailures += 1
        print("[Player] Skip \(track.title): \(reason) (\(consecutiveFailures)/\(Self.maxConsecutiveFailures))")
        guard consecutiveFailures < Self.maxConsecutiveFailures else {
            consecutiveFailures = 0
            error = "No playable tracks available"
            stopPlayback()
            return
        }
        // Hop before advancing. A run of unplayable tracks otherwise recurses synchronously
        // (playTrack → handleUnplayable → advanceQueue → playTrack …) up to
        // maxConsecutiveFailures frames deep inside one main-actor turn, each doing file I/O.
        let gen = playbackGeneration
        Task { @MainActor in
            guard self.playbackGeneration == gen else { return } // user already moved on
            self.advanceQueue(forward: true)
        }
    }

    /// An item that errors partway through never posts DidPlayToEndTime, and its player
    /// stops — which the stall detector deliberately ignores. Without this the UI kept
    /// showing "playing" over silence and nothing ever advanced.
    private func handleItemFailedMidPlayback(generation: Int, error: String?) {
        guard generation == playbackGeneration, finishedGeneration != generation else { return }
        finishedGeneration = generation
        let track = currentTrack ?? Track(id: "", videoId: "", title: "?", artist: "", durationSeconds: 0)
        // Don't delete the file: mid-track failures can be transient (decoder/route), and
        // launch validation already purges files that are genuinely unplayable.
        handleUnplayable(track: track, reason: "failed mid-track: \(error ?? "unknown")")
    }

    private func stopPlayback() {
        tearDownPlayer()
        isPlaying = false
        currentTime = 0
        updateNowPlaying()
    }

    /// Lazily create the ONE long-lived AVPlayer + its single time observer.
    /// We reuse this player for the whole session and only swap items — creating a
    /// fresh AVPlayer per track was churning AVFoundation resources and is the classic
    /// cause of intermittent playback crashes / memory growth over a long run.
    private func ensurePlayer() -> AVPlayer {
        if let p = player { return p }
        let p = AVPlayer()
        p.automaticallyWaitsToMinimizeStalling = false
        // Must stay .pause (the default). Build 53 set this to .none, hoping to keep the
        // rate at 1 across a track handoff so watchOS wouldn't see the audio stop — but
        // in practice playback then stopped at the end of EVERY track and had to be
        // skipped by hand, so the end-of-item signal we rely on does not survive it.
        // The gap is kept short instead: playTrack no longer empties the player, and
        // beginPlayback swaps the item and calls play() in the same turn.
        p.actionAtItemEnd = .pause
        player = p
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.handleTimeTick(seconds) }
        }
        return p
    }

    /// Remove the per-ITEM observers (status + end notification). The player and its
    /// periodic time observer persist across tracks.
    private func removeItemObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        failObserver = nil
    }

    private func beginPlayback(url: URL, generation: Int) {
        guard playbackGeneration == generation else { return }

        let avPlayer = ensurePlayer()
        removeItemObservers()

        // No precise-timing key — that forces a full-file parse per track (memory/CPU).
        // We rely on metadata `knownTrackDuration` for end detection instead.
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        playerItem = item

        let capturedGen = generation

        // End observer captures THIS item's generation so the end notification, duration
        // detection, and stall detection all dedupe against the same generation.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleTrackFinished(generation: capturedGen) }
        }
        failObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in self?.handleItemFailedMidPlayback(generation: capturedGen, error: reason) }
        }
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] observedItem, _ in
            let status = observedItem.status
            let dur = observedItem.duration.seconds
            let errMsg = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                guard let self,
                      self.playbackGeneration == capturedGen,
                      self.playerItem === observedItem else { return }
                switch status {
                case .readyToPlay:
                    self.consecutiveFailures = 0 // successful start resets the skip guard
                    // beginPlayback already requested playback and set the intent. Re-issue
                    // play() only if that intent still stands, so pausing while a track is
                    // loading isn't overridden the moment it becomes ready.
                    if self.isPlaying {
                        self.player?.play()
                        self.player?.volume = self.currentVolume
                    }
                    // Heal old-version downloads (durationSeconds=0) from the asset's
                    // duration BEFORE publishing Now Playing, otherwise the lock screen
                    // gets a 0-duration entry with a dead scrubber for those tracks.
                    // Persisting is deferred, so this stays cheap.
                    if self.knownTrackDuration <= 0, !dur.isNaN, dur > 0 {
                        self.duration = dur
                        if let vid = self.currentTrack?.videoId {
                            WatchFileReceiver.shared.updateTrackDuration(videoId: vid, duration: Int(dur.rounded()))
                        }
                    }
                    self.updateNowPlaying()
                    self.saveLastPlayed()
                    let artworkGen = capturedGen
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        guard self.playbackGeneration == artworkGen else { return }
                        self.updateNowPlaying()
                    }
                case .failed:
                    // A failing item can also post FailedToPlayToEndTime; both routes
                    // share finishedGeneration so one bad track is skipped exactly once.
                    guard self.finishedGeneration != capturedGen else { return }
                    self.finishedGeneration = capturedGen
                    let msg = errMsg ?? "Playback failed"
                    let failed = self.currentTrack
                    print("[Player] \u{2717} \(failed?.title ?? "?"): \(msg)")
                    // Corrupt file — delete it + ask the phone to re-send a clean copy.
                    if let vid = failed?.videoId, !vid.isEmpty {
                        WatchFileReceiver.shared.deleteCorruptAudioFile(videoId: vid)
                        WatchFileReceiver.shared.requestRedownload(videoIds: [vid])
                    }
                    self.handleUnplayable(track: failed ?? Track(id: "", videoId: "", title: "?", artist: "", durationSeconds: 0), reason: "load failed")
                default:
                    break
                }
            }
        }

        // Swap the item into the persistent player (no per-track AVPlayer churn) and ask
        // for playback in the same turn. AVPlayer honours the request as soon as the item
        // is ready, so we don't depend on the async .readyToPlay callback running — which
        // it may not, if the app was suspended during a silent handoff.
        avPlayer.replaceCurrentItem(with: item)
        avPlayer.volume = currentVolume
        avPlayer.play()
        isPlaying = true
        startStallTimer()
    }

    private func startStallTimer() {
        stallTimer?.invalidate()
        stallTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.currentTrack != nil, let player = self.player else { return }
                let t = player.currentTime().seconds

                // Watchdog first: it covers the stopped-player case the stall detector
                // ignores. If it changed track, this tick's samples are stale.
                if self.runPlaybackWatchdog(player: player, time: t) { return }

                // Track finished but the end notification never reached us: advance now
                // instead of leaving playback stopped until the user skips by hand.
                if EndOfItemDetector.isParkedAtEnd(
                    time: t,
                    itemDuration: self.playerItem?.duration.seconds,
                    rate: player.rate,
                    intendsToPlay: self.isPlaying
                ) {
                    self.handleTrackFinished(generation: self.playbackGeneration)
                    return
                }

                guard self.isPlaying, player.rate > 0 else {
                    // System paused/ducked playback (route change, brief throttle, etc) —
                    // see StallDetector.reset() for why this must not count as a stall.
                    self.stallDetector.reset()
                    return
                }

                let outcome = self.stallDetector.tick(
                    time: t,
                    metadataDuration: self.duration,
                    assetDuration: self.playerItem?.duration.seconds
                )
                if outcome == .stalled {
                    self.handleTrackFinished(generation: self.playbackGeneration)
                }
            }
        }
    }

    /// Returns true when it moved off the current track (or stopped).
    private func runPlaybackWatchdog(player: AVPlayer, time: Double) -> Bool {
        switch playbackWatchdog.tick(intendsToPlay: isPlaying, rate: player.rate, time: time) {
        case .none:
            return false
        case .nudge:
            print("[Player] Watchdog: silent while playing — re-issuing play()")
            player.play()
            return false
        case .skip:
            let track = currentTrack ?? Track(id: "", videoId: "", title: "?", artist: "", durationSeconds: 0)
            finishedGeneration = playbackGeneration // dedupe a late end notification
            handleUnplayable(track: track, reason: "no playback for 8s")
            return true
        case .giveUp:
            // Two tracks in a row never produced audio: the problem isn't the files.
            // Stop cleanly rather than cycling the whole library every 8 seconds.
            print("[Player] Watchdog: consecutive tracks never played — stopping")
            pause()
            error = "Playback stopped. Check your headphones and tap play."
            return true
        }
    }

    private func stopStallTimer() {
        stallTimer?.invalidate()
        stallTimer = nil
    }

    /// Periodic playback tick (drives progress, end detection, Now Playing).
    private func handleTimeTick(_ t: Double) {
        guard currentTrack != nil, !t.isNaN else { return }
        if isPlaying, abs(t - currentTime) > 0.05 { lastAudibleAt = Date() }
        currentTime = t
        var needsNowPlayingUpdate = false

        // Fall back to container duration only when metadata duration is unknown.
        if knownTrackDuration <= 0 && duration <= 0,
           let d = playerItem?.duration.seconds, !d.isNaN, d > 0 {
            duration = d
            needsNowPlayingUpdate = true
        }

        // NOTE: do NOT feed `stallDetector` here — it is owned exclusively by the
        // stall timer, which compares consecutive samples of its own. If this periodic
        // observer also ticked it, the two 0.5s timers can drift into phase and the
        // stall check sees "no progress" against a value just set to ~now → false stall
        // → tracks skip mid-play. Keep the two mechanisms independent.

        timeObserverTick += 1
        if needsNowPlayingUpdate || timeObserverTick % 2 == 0 {
            updateNowPlaying()
        }
        if timeObserverTick % 20 == 0 { saveLastPlayed() }
    }

    /// Stop the current item but keep the persistent player + time observer alive.
    private func tearDownPlayer() {
        removeItemObservers()
        stopStallTimer()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
    }

    /// Handle a track finishing. `generation` is the generation of the item that
    /// finished — dedupes the three finish signals (end notification, duration
    /// detection, stall detection) so a track is only advanced once.
    private func handleTrackFinished(generation: Int) {
        // Only act on the currently-playing generation, and only once for it.
        guard generation == playbackGeneration else { return }
        guard finishedGeneration != generation else { return }
        finishedGeneration = generation

        // Sleep timer: end-of-track mode
        if isSleepTimerEndOfTrack {
            cancelSleepTimer()
            pause()
            haptic(.stop)
            return
        }

        switch repeatMode {
        case .one:
            // Replay same track (playTrack bumps generation so it can finish again)
            playTrack(at: currentIndex)
        case .all, .none:
            // advanceQueue handles end-of-queue: .all restarts, .none moves to next album
            advanceQueue(forward: true)
        }
    }

    private func playNextPlaylist() {
        let all = WatchFileReceiver.shared.availablePlaylists
        guard !all.isEmpty else { stopPlayback(); return }

        let currentId = currentPlaylist?.id
        let startIdx = all.firstIndex(where: { $0.id == currentId }) ?? -1

        // Walk forward looking for the next album/playlist that has playable tracks.
        for offset in 1...all.count {
            let idx = ((startIdx < 0 ? 0 : startIdx) + offset) % all.count
            let candidate = all[idx]

            if candidate.id == currentId {
                // Wrapped all the way back to the current playlist.
                if repeatMode == .all {
                    currentPlaylist = candidate
                    consecutiveFailures = 0
                    buildQueue(startingAt: 0)
                    if let ci = queue.currentIndex {
                        currentIndex = ci
                        playTrack(at: ci)
                        return
                    }
                }
                break
            }

            let candidateAvail = availableIndices(in: candidate)
            if !candidateAvail.isEmpty {
                currentPlaylist = candidate
                consecutiveFailures = 0
                buildQueue(startingAt: candidateAvail.first ?? 0)
                if let ci = queue.currentIndex {
                    currentIndex = ci
                    playTrack(at: ci)
                    return
                }
            }
        }
        // Nothing playable anywhere — stop cleanly.
        stopPlayback()
    }

    // MARK: - Now Playing + Remote Controls

    private var cachedArtwork: (videoId: String, artwork: MPMediaItemArtwork)?

    private func updateNowPlaying() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track = currentTrack else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPMediaItemPropertyPlaybackDuration: duration
        ]
        if let album = track.album {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let artwork = artworkForCurrentTrack(track) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        center.nowPlayingInfo = info
        center.playbackState = isPlaying ? .playing : .paused
    }

    private func artworkForCurrentTrack(_ track: Track) -> MPMediaItemArtwork? {
        if let cached = cachedArtwork, cached.videoId == track.videoId {
            return cached.artwork
        }
        guard let url = WatchFileReceiver.shared.thumbnailURL(for: track.videoId),
              let image = Self.downsampledImage(at: url, maxPixel: 300) else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (track.videoId, artwork)
        return artwork
    }

    /// Decode a downsampled image with ImageIO — avoids holding a full-size bitmap
    /// in memory (important on the memory-constrained Watch).
    private static func downsampledImage(at url: URL, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, srcOpts) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private func setupRemoteControls() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayPause() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(to: e.positionTime) }
            return .success
        }
    }

    // MARK: - Interruption Handling

    private func setupInterruptionHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        Task { @MainActor in
            switch type {
            case .began:
                self.wasPlayingBeforeInterruption = self.isPlaying
                self.sessionActivated = false
                self.pause()
            case .ended:
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume) && self.wasPlayingBeforeInterruption {
                        let gen = self.playbackGeneration
                        AVAudioSession.sharedInstance().activate(options: []) { [weak self] success, _ in
                            guard success else { return }
                            Task { @MainActor in
                                guard let self, self.playbackGeneration == gen else { return }
                                self.play()
                            }
                        }
                    }
                }
            @unknown default:
                break
            }
        }
    }

    // MARK: - Route Change Handling

    private func setupRouteChangeHandling() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Task { @MainActor in
            switch reason {
            case .oldDeviceUnavailable:
                // Headphones gone — pause so nothing is lost, but remember it was the route,
                // not the user. On a Watch long-form audio only plays over Bluetooth, and
                // headphones drop out routinely mid-run; previously that stopped playback
                // for good. An interruption may already have paused us a moment earlier,
                // so "was playing" also counts audio confirmed within the last few seconds.
                let wasPlaying = self.isPlaying
                    || (self.lastAudibleAt.map { Date().timeIntervalSince($0) < 3 } ?? false)
                self.pause() // clears any older route-loss marker
                if wasPlaying { self.routeLossPauseDate = Date() }
            case .newDeviceAvailable:
                guard let lost = self.routeLossPauseDate,
                      Date().timeIntervalSince(lost) < Self.routeResumeWindow else { return }
                self.routeLossPauseDate = nil
                print("[Player] Headphones reconnected — resuming")
                // Re-activate first: the session may have been torn down with the route.
                AVAudioSession.sharedInstance().activate(options: []) { success, _ in
                    Task { @MainActor in
                        if success { self.sessionActivated = true }
                        self.play()
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Last-Played Persistence

    private func saveLastPlayed() {
        guard let track = currentTrack, let playlist = currentPlaylist else { return }
        let state: [String: Any] = [
            "playlistId": playlist.id,
            "trackVideoId": track.videoId,
            "currentTime": currentTime,
            "currentIndex": currentIndex
        ]
        UserDefaults.standard.set(state, forKey: "lastPlayedState")
    }

    private func restoreLastPlayed() {
        guard let state = UserDefaults.standard.dictionary(forKey: "lastPlayedState"),
              let playlistId = state["playlistId"] as? String,
              let trackVideoId = state["trackVideoId"] as? String,
              let savedTime = state["currentTime"] as? Double,
              let savedIndex = state["currentIndex"] as? Int else { return }

        let playlists = WatchFileReceiver.shared.availablePlaylists
        guard let playlist = playlists.first(where: { $0.id == playlistId }),
              savedIndex >= 0,
              savedIndex < playlist.tracks.count,
              playlist.tracks[savedIndex].videoId == trackVideoId else { return }

        currentPlaylist = playlist
        currentIndex = savedIndex
        let track = playlist.tracks[savedIndex]
        currentTrack = track
        buildQueue(startingAt: savedIndex)
        knownTrackDuration = track.durationSeconds > 0 ? Double(track.durationSeconds) : 0
        duration = knownTrackDuration
        currentTime = savedTime
    }
}
