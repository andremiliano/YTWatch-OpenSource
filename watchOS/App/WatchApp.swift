import SwiftUI

@main
struct YTWatchWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Genuinely first: everything below — library decode, directory scan, WCSession,
        // audio-session setup, queue restore — is where a launch crash would come from, and
        // a handler installed after them can't see it.
        WatchCrashReporter.install()
        let previousCrash = WatchCrashReporter.takePreviousCrash()

        // If a marker survived, the previous run died mid-activity.
        let previous = CrashBreadcrumb.consumePrevious()
        // Stays set until the first view has been built, so a crash in the launch path
        // (library load, view construction) is reported as "launching" rather than as
        // whatever ran last. PlaylistListView's onAppear settles it.
        CrashBreadcrumb.mark(.launching)

        // Record the evidence before doing anything else that could fail.
        WatchDiagnostics.shared.log("launch \(AppVersion.display)")
        if let previous {
            WatchDiagnostics.shared.log("PREVIOUS RUN ENDED UNEXPECTEDLY during: \(previous)")
        }
        if let previousCrash {
            for line in previousCrash.split(separator: "\n").prefix(60) {
                WatchDiagnostics.shared.log(String(line))
            }
        }
        if previous != nil || previousCrash != nil {
            // Sent as soon as WatchConnectivity activates (see WatchFileReceiver), as a small
            // raw log with no directory scans. Waiting a fixed delay missed every crash that
            // happens within seconds of launch — which is exactly the one being chased.
            WatchDiagnostics.shared.crashReportPending = true
        }

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
