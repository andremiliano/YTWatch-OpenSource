import Foundation

/// App version read from the bundle, so what the UI shows can never drift from what was
/// actually shipped. Both targets read the same keys, which makes it possible to confirm
/// at a glance that the Watch app and the iPhone app are the same build.
enum AppVersion {
    /// Marketing version, e.g. "1.1.0" (CFBundleShortVersionString / MARKETING_VERSION).
    static var short: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Build number, e.g. "52" (CFBundleVersion / CURRENT_PROJECT_VERSION).
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// e.g. "1.1.0 (52)"
    static var display: String { "\(short) (\(build))" }
}
