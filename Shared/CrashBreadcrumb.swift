import Foundation

/// Records what the app was doing, so a run that dies without a readable crash log still
/// says something useful on the next launch.
///
/// The marker is cleared when the app backgrounds *without* playing, because being killed
/// while suspended is normal housekeeping, not a crash. A marker that survives means the
/// app died while it was actually doing something — foreground, or playing in the pocket.
enum CrashBreadcrumb {
    private static let currentKey = "breadcrumb.current"
    private static let lastUncleanKey = "breadcrumb.lastUnclean"

    enum Activity {
        case launching
        case validatingDownloads
        case startingTrack(String)
        case advancingQueue
        case applyingMetadata(Int)
        case receivingSync
        case libraryIndex(Int)
        case idle

        var label: String {
            switch self {
            case .launching: return "launching"
            case .validatingDownloads: return "checking downloads"
            // Stays set for the whole track, so a death mid-song names the song.
            case .startingTrack(let title): return "playing \(title.prefix(40))"
            case .advancingQueue: return "changing track"
            case .applyingMetadata(let n): return "recovering \(n) titles"
            case .receivingSync: return "receiving sync"
            case .libraryIndex(let n): return "applying \(n) playlists"
            case .idle: return "idle"
            }
        }
    }

    static func mark(_ activity: Activity) {
        UserDefaults.standard.set(activity.label, forKey: currentKey)
    }

    /// Clear the marker for a legitimate exit (backgrounded with nothing in flight).
    static func clearForCleanExit() {
        UserDefaults.standard.removeObject(forKey: currentKey)
    }

    /// Call once at launch. A leftover marker means the previous run ended abruptly.
    @discardableResult
    static func consumePrevious() -> String? {
        let defaults = UserDefaults.standard
        guard let leftover = defaults.string(forKey: currentKey) else { return nil }
        let stamped = "\(leftover) · \(Self.timestamp())"
        defaults.set(stamped, forKey: lastUncleanKey)
        defaults.removeObject(forKey: currentKey)
        print("[Breadcrumb] Previous run ended during: \(leftover)")
        return stamped
    }

    /// Shown in the Watch's Storage screen so a crash can be reported concretely.
    static var lastUnclean: String? { UserDefaults.standard.string(forKey: lastUncleanKey) }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM HH:mm"
        return f.string(from: Date())
    }
}
