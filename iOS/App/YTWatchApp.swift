import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        if identifier == AudioDownloader.backgroundSessionId {
            AudioDownloader.backgroundSessionCompletionHandler = completionHandler
            // Accessing .shared ensures the background session reconnects
            _ = AudioDownloader.shared
        }
    }
}

@main
struct YTWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var client = YTMusicClient.shared

    init() {
        YTMusicClient.shared.loadSavedCookies()
        _ = WatchSyncManager.shared
        WatchSyncManager.shared.requestNotificationPermission()

        // Force dark tab bar / nav bar appearance globally
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(red: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance

        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor(red: 0.047, green: 0.047, blue: 0.047, alpha: 1)
        navAppearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navAppearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
    }

    var body: some Scene {
        WindowGroup {
            if client.isAuthenticated {
                ContentView()
            } else {
                AuthView()
            }
        }
    }
}

struct ContentView: View {
    init() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Color.appBg)
        appearance.shadowColor = UIColor(white: 1, alpha: 0.06)
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView {
            LibraryView()
                .tabItem {
                    Label("Library", systemImage: "music.note.list")
                }

            ForYouView()
                .tabItem {
                    Label("For You", systemImage: "wand.and.stars")
                }

            ExploreView()
                .tabItem {
                    Label("Explore", systemImage: "safari")
                }

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
        .preferredColorScheme(.dark)
        .tint(Color.ytRed)
    }
}
