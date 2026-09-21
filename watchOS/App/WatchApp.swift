import SwiftUI

@main
struct YTWatchWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before anything else: if a marker survived, the previous run died mid-activity.
        let previous = CrashBreadcrumb.consumePrevious()
        // Stays set until the first view has been built, so a crash in the launch path
        // (library load, view construction) is reported as "launching" rather than as
        // whatever ran last. PlaylistListView's onAppear settles it.
        CrashBreadcrumb.mark(.launching)
        _ = WatchFileReceiver.shared  // activate WCSession
        WatchPlayer.shared.configureAudioSession()

        WatchDiagnostics.shared.log("launch \(AppVersion.display)")
        if let previous {
            WatchDiagnostics.shared.log("PREVIOUS RUN ENDED UNEXPECTEDLY during: \(previous)")
            // Get the evidence off the Watch without the user having to remember. The
            // transfer queues until the iPhone is next in range.
            WatchDiagnostics.shared.sendToPhone(reason: "automatic after unexpected stop")
        }
    }

    var body: some Scene {
        WindowGroup {
            PlaylistListView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                WatchDiagnostics.shared.log("app active")
                // Re-sync sleep timer from absolute target after background
                WatchPlayer.shared.refreshSleepTimer()
            case .background:
                // Screen-off/wrist-down is when playback problems are reported, so record
                // the transition — it's what correlates a stop with the app backgrounding.
                WatchDiagnostics.shared.log("app backgrounded (playing: \(WatchPlayer.shared.isPlaying))")
                WatchDiagnostics.shared.flush()
                // Persist any deferred playlist changes before we can be suspended —
                // audio files are written immediately, but their metadata is debounced,
                // so without this a sync that finishes just before backgrounding leaves
                // tracks on disk that no playlist knows about.
                WatchFileReceiver.shared.flushLibraryNow()
                // Being killed while suspended with nothing in flight is routine, not a
                // crash. Anything still running (playback, an in-progress sync) keeps its
                // marker so a death there is still reported.
                if !WatchPlayer.shared.isPlaying && WatchFileReceiver.shared.receivingCount == 0 {
                    CrashBreadcrumb.clearForCleanExit()
                }
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
