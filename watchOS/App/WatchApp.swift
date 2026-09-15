import SwiftUI

@main
struct YTWatchWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        _ = WatchFileReceiver.shared  // activate WCSession
        WatchPlayer.shared.configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            PlaylistListView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Re-sync sleep timer from absolute target after background
                WatchPlayer.shared.refreshSleepTimer()
            case .background:
                // Persist any deferred playlist changes before we can be suspended —
                // audio files are written immediately, but their metadata is debounced,
                // so without this a sync that finishes just before backgrounding leaves
                // tracks on disk that no playlist knows about.
                WatchFileReceiver.shared.flushLibraryNow()
                // Free image memory while the screen is off (e.g. during a run) —
                // keeps the app well under the Watch's memory ceiling so long
                // playback sessions don't get jetsammed.
                WatchThumbnailCache.shared.clear()
            default:
                break
            }
        }
    }
}
