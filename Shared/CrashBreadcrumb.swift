import Foundation

/// Records what the app was doing, so a run that dies without a readable crash log still
/// says something useful on the next launch.
///
/// Every activity that sets a marker must clear it when it finishes (`.idle`), otherwise a
/// marker left behind by work that completed long ago gets reported as the cause of a much
/// later death. A marker that survives a launch means the app stopped while that activity
/// was genuinely in flight.
enum CrashBreadcrumb {
    private static let currentKey = "breadcrumb.current"
    private static let lastUncleanKey = "breadcrumb.lastUnclean"
    private static let lastUncleanDateKey = "breadcrumb.lastUncleanDate"
    private static let uncleanCountKey = "breadcrumb.uncleanCount"

    enum Activity: Equatable {
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
        if case .idle = activity {
            UserDefaults.standard.removeObject(forKey: currentKey)
        } else {
            UserDefaults.standard.set(activity.label, forKey: currentKey)
        }
    }

    /// Clear the marker for a legitimate exit (nothing in flight).
    static func clearForCleanExit() {
        UserDefaults.standard.removeObject(forKey: currentKey)
    }

    /// Call once at launch. A leftover marker means the previous run ended abruptly.
    @discardableResult
    static func consumePrevious() -> String? {
        let defaults = UserDefaults.standard
        guard let leftover = defaults.string(forKey: currentKey) else { return nil }
        defaults.removeObject(forKey: currentKey)
        defaults.set(leftover, forKey: lastUncleanKey)
        defaults.set(Date(), forKey: lastUncleanDateKey)
        defaults.set(defaults.integer(forKey: uncleanCountKey) + 1, forKey: uncleanCountKey)
        print("[Breadcrumb] Previous run ended during: \(leftover)")
        return leftover
    }

    /// What the app was doing when it last stopped unexpectedly, if ever.
    static var lastUnclean: String? { UserDefaults.standard.string(forKey: lastUncleanKey) }
    static var lastUncleanDate: Date? { UserDefaults.standard.object(forKey: lastUncleanDateKey) as? Date }
    /// How many unexpected stops have been recorded — tells a one-off from a recurring one.
    static var uncleanCount: Int { UserDefaults.standard.integer(forKey: uncleanCountKey) }

    /// e.g. "playing Some Song · 21 Sep 2026 14:03 (3rd)"
    static var summary: String? {
        guard let activity = lastUnclean else { return nil }
        var text = activity
        if let date = lastUncleanDate {
            let f = DateFormatter()
            f.dateFormat = "d MMM yyyy HH:mm"
            text += " · \(f.string(from: date))"
        }
        let count = uncleanCount
        if count > 1 { text += " (\(count)×)" }
        return text
    }

    /// Wipe the recorded history — used after the user exports diagnostics, so the next
    /// report reflects only what happened since.
    static func clearHistory() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: lastUncleanKey)
        defaults.removeObject(forKey: lastUncleanDateKey)
        defaults.removeObject(forKey: uncleanCountKey)
    }
}
