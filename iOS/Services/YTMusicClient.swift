//
//  YTMusicClient.swift
//  YTWatch
//
//  Interfaces with YouTube Music's internal web API endpoints (acting as a first-party client).
//
//  Architecture Notes:
//  - Avoids quota-limited Data APIs entirely.
//  - Authentication is handled seamlessly by capturing cookies from a `WKWebView` Google login.
//  - Generates `SAPISIDHASH` authorization headers dynamically from cookies.
//  - Decrypts ciphered stream URLs using a headless `JavaScriptCore` context.
//

import Foundation
import WebKit
import JavaScriptCore
import CryptoKit

@MainActor
final class YTMusicClient: NSObject, ObservableObject {

    static let shared = YTMusicClient()

    @Published var isAuthenticated = false
    @Published var userDisplayName: String?
    @Published var authError: String?

    private var authCookies: [HTTPCookie] = []
    private var visitorData: String = ""

    // MARK: - Auth

    func loadSavedCookies() {
        guard let data = KeychainHelper.load(key: "ytm_cookies"),
              let decoded = try? JSONDecoder().decode([CookieArchive].self, from: data) else { return }
        authCookies = decoded.compactMap { $0.cookie }
        isAuthenticated = !authCookies.isEmpty
        userDisplayName = UserDefaults.standard.string(forKey: "ytm_display_name")
        if isAuthenticated {
            Task { await refreshSessionData() }
        }
    }

    func saveCookies(_ cookies: [HTTPCookie]) {
        authCookies = cookies
        let archives = cookies.map { CookieArchive(cookie: $0) }
        if let data = try? JSONEncoder().encode(archives) {
            KeychainHelper.save(data, key: "ytm_cookies")
        }
        isAuthenticated = true
        Task { await refreshSessionData() }
    }

    private func refreshSessionData() async {
        await fetchVisitorData()
        await fetchUserProfile()
    }

    // Fetches visitorData (and tries to extract account name) from the YTM home page.
    private func fetchVisitorData() async {
        var req = URLRequest(url: URL(string: "https://music.youtube.com/")!)
        req.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            print("[YTM] home page fetch failed")
            return
        }

        extractVisitorData(from: html)
        extractAccountNameFromHTML(html)
    }

    private func extractVisitorData(from html: String) {
        let patterns = [#""VISITOR_DATA"\s*:\s*"([^"]+)""#, #"visitorData"\s*:\s*"([^"]+)""#]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                visitorData = String(html[r])
                print("[YTM] visitorData: \(visitorData.prefix(16))…")
                return
            }
        }
        print("[YTM] visitorData not found")
    }

    private func extractAccountNameFromHTML(_ html: String) {
        // Patterns that appear in ytInitialData / ytInitialGuideData embedded in the page
        let patterns = [
            #""accountName"\s*:\s*\{"runs"\s*:\s*\[\{"text"\s*:\s*"([^"]+)""#,
            #""activeAccountName"\s*:\s*\{"runs"\s*:\s*\[\{"text"\s*:\s*"([^"]+)""#,
            #""channelTitle"\s*:\s*"([^"@][^"]{1,50})""#
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p),
               let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                let name = String(html[r])
                print("[YTM] account name from HTML: \(name)")
                if userDisplayName == nil {
                    userDisplayName = name
                    UserDefaults.standard.set(name, forKey: "ytm_display_name")
                }
                return
            }
        }
        print("[YTM] account name not found in HTML — will retry via API")
    }

    func logout() {
        authCookies = []
        userDisplayName = nil
        KeychainHelper.delete(key: "ytm_cookies")
        UserDefaults.standard.removeObject(forKey: "ytm_display_name")
        isAuthenticated = false
    }

    // Fetches the signed-in account name to confirm cookies are valid.
    func fetchUserProfile() async {
        guard let name = await fetchAccountName() else { return }
        userDisplayName = name
        UserDefaults.standard.set(name, forKey: "ytm_display_name")
    }

    private func fetchAccountName() async -> String? {
        for endpoint in ["account/account_menu", "account/get_setting"] {
            guard let data = try? await ytmRequest(endpoint: endpoint, body: [:]) else { continue }
            print("[YTM] \(endpoint) response: \(String(data: data, encoding: .utf8)?.prefix(2000) ?? "")")
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let name = extractAccountName(from: json) { return name }
        }
        return nil
    }

    private func extractAccountName(from json: [String: Any]) -> String? {
        // Find activeAccountHeaderRenderer anywhere in the tree, then pull accountName
        func findAccountHeader(_ obj: Any) -> [String: Any]? {
            if let dict = obj as? [String: Any] {
                if dict["accountName"] != nil && dict["accountPhoto"] != nil { return dict }
                for v in dict.values { if let found = findAccountHeader(v) { return found } }
            } else if let arr = obj as? [Any] {
                for item in arr { if let found = findAccountHeader(item) { return found } }
            }
            return nil
        }

        if let header = findAccountHeader(json),
           let accountName = header["accountName"] as? [String: Any],
           let runs = accountName["runs"] as? [[String: Any]],
           let text = runs.first?["text"] as? String, !text.isEmpty {
            return text
        }

        // Fallback: any compactLinkRenderer title that isn't an email
        func findFirstNonEmail(_ obj: Any) -> String? {
            if let dict = obj as? [String: Any] {
                if let title = dict["title"] as? [String: Any],
                   let runs = title["runs"] as? [[String: Any]],
                   let text = runs.first?["text"] as? String,
                   !text.contains("@"), !text.isEmpty, text.count < 60 {
                    return text
                }
                for v in dict.values { if let found = findFirstNonEmail(v) { return found } }
            } else if let arr = obj as? [Any] {
                for item in arr { if let found = findFirstNonEmail(item) { return found } }
            }
            return nil
        }
        return findFirstNonEmail(json)
    }

    // MARK: - API

    struct SearchResults {
        var songs: [Track] = []
        var albums: [Playlist] = []
    }

    struct HomeFeedSection: Identifiable {
        let id = UUID()
        let title: String
        var playlists: [Playlist]
        var tracks: [Track]
    }

    func search(query: String) async throws -> SearchResults {
        let data = try await ytmRequest(endpoint: "search", body: ["query": query])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return SearchResults()
        }

        var songs: [Track] = []
        var albums: [Playlist] = []
        var seenSongs = Set<String>()
        var seenAlbums = Set<String>()

        var stack: [Any] = [json]
        while let obj = stack.popLast() {
            if let dict = obj as? [String: Any] {
                if let shelf = dict["musicShelfRenderer"] as? [String: Any] {
                    let shelfTitle = ((shelf["title"] as? [String: Any])?["runs"] as? [[String: Any]])?
                        .first?["text"] as? String ?? ""
                    let contents = shelf["contents"] as? [Any] ?? []
                    let isAlbumShelf = shelfTitle.lowercased().contains("album") || shelfTitle.lowercased().contains("single")

                    for item in contents {
                        let itemDict = item as? [String: Any]
                        if isAlbumShelf {
                            // Albums via musicTwoRowItemRenderer
                            if let r = itemDict?["musicTwoRowItemRenderer"] as? [String: Any],
                               let p = parsePlaylistRenderer(r),
                               seenAlbums.insert(p.id).inserted { albums.append(p) }
                            // Albums also appear as musicResponsiveListItemRenderer with browse endpoint
                            if let r = itemDict?["musicResponsiveListItemRenderer"] as? [String: Any],
                               let p = parseAlbumFromResponsiveRenderer(r),
                               seenAlbums.insert(p.id).inserted { albums.append(p) }
                        } else {
                            if let r = itemDict?["musicResponsiveListItemRenderer"] as? [String: Any],
                               let t = parseTrackRenderer(r),
                               seenSongs.insert(t.id).inserted { songs.append(t) }
                        }
                    }
                }
                // Top result cards (musicCardShelfRenderer) can contain albums
                if let card = dict["musicCardShelfRenderer"] as? [String: Any] {
                    if let nav = card["title"] as? [String: Any],
                       let runs = nav["runs"] as? [[String: Any]],
                       let firstRun = runs.first,
                       let navEnd = firstRun["navigationEndpoint"] as? [String: Any],
                       let browse = navEnd["browseEndpoint"] as? [String: Any],
                       let browseId = browse["browseId"] as? String,
                       (browseId.hasPrefix("MPRE") || browseId.hasPrefix("OLAK")),
                       let title = firstRun["text"] as? String {
                        let subtitleRuns = (card["subtitle"] as? [String: Any])?["runs"] as? [[String: Any]]
                        let subtitle = subtitleRuns?.compactMap { $0["text"] as? String }.joined()
                        let thumbRenderer = (card["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
                        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
                        let thumbnailURL = (thumbObj?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String
                        let pid = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
                        let p = Playlist(id: pid, title: title, subtitle: subtitle, thumbnailURL: thumbnailURL, tracks: [])
                        if seenAlbums.insert(p.id).inserted { albums.append(p) }
                    }
                }
                stack.append(contentsOf: dict.values)
            } else if let arr = obj as? [Any] {
                stack.append(contentsOf: arr)
            }
        }

        return SearchResults(songs: songs, albums: albums)
    }

    func fetchHomeFeed() async throws -> [Playlist] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        return try parsePlaylistsFromBrowse(data)
    }

    func fetchHomeFeedSectioned() async throws -> [HomeFeedSection] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_home"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }
        return parseHomeSections(json)
    }

    func fetchRecentlyPlayed() async throws -> [Track] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_history"])
        return try parseTracksFromPlaylist(data)
    }

    // MARK: - Search Suggestions

    func fetchSearchSuggestions(query: String) async throws -> [String] {
        let data = try await ytmRequest(endpoint: "music/get_search_suggestions", body: ["input": query])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var suggestions: [String] = []
        var stack: [Any] = [json]
        while let obj = stack.popLast() {
            if let dict = obj as? [String: Any] {
                if let runs = dict["runs"] as? [[String: Any]] {
                    let text = runs.compactMap { $0["text"] as? String }.joined()
                    if !text.isEmpty && !suggestions.contains(text) { suggestions.append(text) }
                }
                if let query = dict["query"] as? String, !query.isEmpty, !suggestions.contains(query) {
                    suggestions.append(query)
                }
                stack.append(contentsOf: dict.values)
            } else if let arr = obj as? [Any] {
                stack.append(contentsOf: arr)
            }
        }
        return Array(suggestions.prefix(8))
    }

    // MARK: - Explore

    func fetchExplore() async throws -> [HomeFeedSection] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_explore"])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }
        return parseHomeSections(json)
    }

    func fetchNewReleases() async throws -> [Playlist] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_new_releases_albums"])
        return try parsePlaylistsFromBrowse(data)
    }

    struct MoodCategory: Identifiable {
        let id = UUID()
        let title: String
        let params: String
        let color: String?
    }

    func fetchMoodsAndGenres() async throws -> [MoodCategory] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_moods_and_genres"])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        var categories: [MoodCategory] = []
        var stack: [Any] = [json]
        while let obj = stack.popLast() {
            if let dict = obj as? [String: Any] {
                if let chip = dict["musicNavigationButtonRenderer"] as? [String: Any] {
                    let title = (chip["buttonText"] as? [String: Any])?["runs"] as? [[String: Any]]
                    let text = title?.first?["text"] as? String ?? ""
                    let nav = chip["clickCommand"] as? [String: Any]
                        ?? chip["navigationEndpoint"] as? [String: Any]
                    let browse = nav?["browseEndpoint"] as? [String: Any]
                    let params = browse?["params"] as? String ?? ""
                    let solid = (chip["solid"] as? [String: Any])?["leftStripeColor"] as? Int
                    let colorHex = solid.map { String(format: "#%06X", $0 & 0xFFFFFF) }
                    if !text.isEmpty && !params.isEmpty {
                        categories.append(MoodCategory(title: text, params: params, color: colorHex))
                    }
                }
                stack.append(contentsOf: dict.values)
            } else if let arr = obj as? [Any] {
                stack.append(contentsOf: arr)
            }
        }
        return categories
    }

    func fetchMoodPlaylists(params: String) async throws -> [Playlist] {
        let data = try await ytmRequest(endpoint: "browse", body: [
            "browseId": "FEmusic_moods_and_genres_category",
            "params": params
        ])
        return try parsePlaylistsFromBrowse(data)
    }

    // MARK: - Library Songs

    func fetchLibrarySongs() async throws -> [Track] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_liked_videos"])
        return try parseTracksFromPlaylist(data)
    }

    // MARK: - Artist

    struct ArtistPage {
        let name: String
        let channelId: String
        let thumbnailURL: String?
        let subscriberCount: String?
        var topSongs: [Track]
        var albums: [Playlist]
        var singles: [Playlist]
    }

    func fetchArtist(channelId: String) async throws -> ArtistPage {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": channelId])
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid artist response")
        }

        var name = "Artist"
        var thumbnailURL: String?
        var subscriberCount: String?
        var topSongs: [Track] = []
        var albums: [Playlist] = []
        var singles: [Playlist] = []

        func findHeader(_ obj: Any, depth: Int = 0) -> [String: Any]? {
            guard depth < 15 else { return nil }
            if let dict = obj as? [String: Any] {
                for key in ["musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer", "musicResponsiveHeaderRenderer"] {
                    if let h = dict[key] as? [String: Any] { return h }
                }
                for v in dict.values { if let f = findHeader(v, depth: depth + 1) { return f } }
            } else if let arr = obj as? [Any] {
                for item in arr { if let f = findHeader(item, depth: depth + 1) { return f } }
            }
            return nil
        }
        if let header = findHeader(json) {
            if let titleObj = header["title"] as? [String: Any],
               let runs = titleObj["runs"] as? [[String: Any]] {
                name = runs.compactMap { $0["text"] as? String }.joined()
            }
            if let thumbObj = header["thumbnail"] as? [String: Any] {
                let renderer = thumbObj["musicThumbnailRenderer"] as? [String: Any] ?? thumbObj
                let inner = (renderer["thumbnail"] as? [String: Any]) ?? renderer
                let thumbs = inner["thumbnails"] as? [[String: Any]]
                thumbnailURL = thumbs?.last?["url"] as? String
            }
            if let subObj = header["subscriptionButton"] as? [String: Any],
               let subRenderer = subObj["subscribeButtonRenderer"] as? [String: Any],
               let subText = subRenderer["subscriberCountText"] as? [String: Any],
               let runs = subText["runs"] as? [[String: Any]] {
                subscriberCount = runs.compactMap { $0["text"] as? String }.joined()
            }
        }

        var shelfStack: [(Any, Int)] = [(json, 0)]
        while let (obj, depth) = shelfStack.popLast() {
            guard depth < 20 else { continue }
            if let dict = obj as? [String: Any] {
                if let shelf = dict["musicShelfRenderer"] as? [String: Any] {
                    let shelfTitle = ((shelf["title"] as? [String: Any])?["runs"] as? [[String: Any]])?
                        .first?["text"] as? String ?? ""
                    if shelfTitle.lowercased().contains("song") {
                        if let contents = shelf["contents"] as? [Any] {
                            for item in contents {
                                if let r = (item as? [String: Any])?["musicResponsiveListItemRenderer"] as? [String: Any],
                                   let t = parseTrackRenderer(r, fallbackArtist: name) {
                                    topSongs.append(t)
                                }
                            }
                        }
                    }
                }
                if let carousel = dict["musicCarouselShelfRenderer"] as? [String: Any] {
                    let carouselTitle = ((carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any])?["title"] as? [String: Any]
                    let titleText = (carouselTitle?["runs"] as? [[String: Any]])?.first?["text"] as? String ?? ""

                    if let contents = carousel["contents"] as? [Any] {
                        for item in contents {
                            if let r = (item as? [String: Any])?["musicTwoRowItemRenderer"] as? [String: Any],
                               let p = parsePlaylistRenderer(r) {
                                if titleText.lowercased().contains("single") {
                                    singles.append(p)
                                } else if titleText.lowercased().contains("album") {
                                    albums.append(p)
                                } else {
                                    albums.append(p)
                                }
                            }
                        }
                    }
                }
                for v in dict.values { shelfStack.append((v, depth + 1)) }
            } else if let arr = obj as? [Any] {
                for item in arr { shelfStack.append((item, depth + 1)) }
            }
        }

        return ArtistPage(
            name: name,
            channelId: channelId,
            thumbnailURL: thumbnailURL,
            subscriberCount: subscriberCount,
            topSongs: topSongs,
            albums: albums,
            singles: singles
        )
    }

    // MARK: - Radio

    func fetchRadio(videoId: String) async throws -> Playlist {
        let data = try await ytmRequest(endpoint: "next", body: [
            "videoId": videoId,
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
            "tunerSettingValue": "AUTOMIX_SETTING_NORMAL"
        ])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid radio response")
        }

        var tracks: [Track] = []
        var playlistTitle = "Radio"

        var radioStack: [(Any, Int)] = [(json, 0)]
        while let (obj, depth) = radioStack.popLast() {
            guard depth < 20 else { continue }
            if let dict = obj as? [String: Any] {
                if let panel = dict["playlistPanelRenderer"] as? [String: Any] {
                    if let t = panel["title"] as? String {
                        playlistTitle = t
                    } else if let titleObj = panel["titleText"] as? [String: Any],
                              let runs = titleObj["runs"] as? [[String: Any]] {
                        playlistTitle = runs.compactMap { $0["text"] as? String }.joined()
                    }
                    if let contents = panel["contents"] as? [Any] {
                        for item in contents {
                            if let itemDict = item as? [String: Any],
                               let renderer = itemDict["playlistPanelVideoRenderer"] as? [String: Any],
                               let track = parseRadioTrack(renderer) {
                                tracks.append(track)
                            }
                        }
                    }
                }
                for v in dict.values { radioStack.append((v, depth + 1)) }
            } else if let arr = obj as? [Any] {
                for item in arr { radioStack.append((item, depth + 1)) }
            }
        }

        return Playlist(id: "RADIO_\(videoId)", title: playlistTitle, thumbnailURL: nil, tracks: tracks)
    }

    private func parseRadioTrack(_ r: [String: Any]) -> Track? {
        guard let videoId = r["videoId"] as? String else { return nil }

        let titleRuns = (r["title"] as? [String: Any])?["runs"] as? [[String: Any]]
        let title = titleRuns?.compactMap { $0["text"] as? String }.joined() ?? "Unknown"

        let artistRuns = (r["longBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
            ?? (r["shortBylineText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let artist = artistRuns?.compactMap { $0["text"] as? String }
            .filter { $0 != " • " && $0 != " & " && $0 != ", " }
            .first ?? "Unknown"

        let durText = (r["lengthText"] as? [String: Any])?["runs"] as? [[String: Any]]
        let durStr = durText?.first?["text"] as? String ?? ""
        let duration = parseDuration(durStr)

        let thumbs = (r["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbs?.last?["url"] as? String

        return Track(id: videoId, videoId: videoId, title: title, artist: artist, album: nil, durationSeconds: duration, thumbnailURL: thumbnailURL)
    }

    private func parseHomeSections(_ json: [String: Any]) -> [HomeFeedSection] {
        var sections: [HomeFeedSection] = []

        var sectionStack: [(Any, Int)] = [(json, 0)]
        while let (obj, depth) = sectionStack.popLast() {
            guard depth < 20 else { continue }
            if let dict = obj as? [String: Any] {
                if let carousel = dict["musicCarouselShelfRenderer"] as? [String: Any] {
                    if let section = parseCarouselSection(carousel) { sections.append(section) }
                } else if let shelf = dict["musicShelfRenderer"] as? [String: Any] {
                    if let section = parseShelfSection(shelf) { sections.append(section) }
                } else {
                    for v in dict.values { sectionStack.append((v, depth + 1)) }
                }
            } else if let arr = obj as? [Any] {
                for item in arr { sectionStack.append((item, depth + 1)) }
            }
        }
        return sections
    }

    private func parseCarouselSection(_ carousel: [String: Any]) -> HomeFeedSection? {
        let title = extractShelfTitle(carousel)
        let items = carousel["contents"] as? [Any] ?? []
        var playlists: [Playlist] = []
        var tracks: [Track] = []

        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            if let r = dict["musicTwoRowItemRenderer"] as? [String: Any],
               let p = parsePlaylistRenderer(r) {
                playlists.append(p)
            } else if let r = dict["musicResponsiveListItemRenderer"] as? [String: Any],
                      let t = parseTrackRenderer(r) {
                tracks.append(t)
            }
        }
        guard !playlists.isEmpty || !tracks.isEmpty else { return nil }
        return HomeFeedSection(title: title, playlists: playlists, tracks: tracks)
    }

    private func parseShelfSection(_ shelf: [String: Any]) -> HomeFeedSection? {
        let title = extractShelfTitle(shelf)
        let contents = shelf["contents"] as? [Any] ?? []
        var tracks: [Track] = []
        var playlists: [Playlist] = []

        for item in contents {
            guard let dict = item as? [String: Any] else { continue }
            if let r = dict["musicResponsiveListItemRenderer"] as? [String: Any],
               let t = parseTrackRenderer(r) {
                tracks.append(t)
            } else if let r = dict["musicTwoRowItemRenderer"] as? [String: Any],
                      let p = parsePlaylistRenderer(r) {
                playlists.append(p)
            }
        }
        guard !playlists.isEmpty || !tracks.isEmpty else { return nil }
        return HomeFeedSection(title: title, playlists: playlists, tracks: tracks)
    }

    private func extractShelfTitle(_ shelf: [String: Any]) -> String {
        if let header = shelf["header"] as? [String: Any] {
            for key in ["musicCarouselShelfBasicHeaderRenderer", "musicShelfBasicHeaderRenderer"] {
                if let h = header[key] as? [String: Any],
                   let titleObj = h["title"] as? [String: Any],
                   let runs = titleObj["runs"] as? [[String: Any]],
                   let text = runs.first?["text"] as? String {
                    return text
                }
            }
        }
        return "Recommended"
    }

    func fetchLikedSongs() async throws -> [Track] {
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": "VLLM"])
        return try parseTracksFromPlaylist(data)
    }

    func fetchLibraryPlaylists() async throws -> [Playlist] {
        let likedData = try await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_liked_playlists"])
        let ownedData = try? await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_library_privately_owned_playlists"])
        let albumsData = try? await ytmRequest(endpoint: "browse", body: ["browseId": "FEmusic_liked_albums"])

        var playlists = (try? parsePlaylistsFromBrowse(likedData)) ?? []
        var seen = Set(playlists.map(\.id))

        if let owned = ownedData, let batch = try? parsePlaylistsFromBrowse(owned) {
            for p in batch where seen.insert(p.id).inserted { playlists.append(p) }
        }
        if let albums = albumsData, let batch = try? parsePlaylistsFromBrowse(albums) {
            for p in batch where seen.insert(p.id).inserted { playlists.append(p) }
        }
        return playlists
    }

    func fetchPlaylistTracks(playlistId: String) async throws -> [Track] {
        // MPREb_ = album release IDs — use as-is (no VL prefix)
        // MPSP*   = podcast shows/episodes — use as-is (no VL prefix)
        // Everything else (PL, RDAMPL, etc.) needs VL prefix for the browse API
        let browseId: String
        if playlistId.hasPrefix("VL") || playlistId.hasPrefix("MPREb_") || playlistId.hasPrefix("MPSP") {
            browseId = playlistId
        } else {
            browseId = "VL\(playlistId)"
        }
        let data = try await ytmRequest(endpoint: "browse", body: ["browseId": browseId])
        return try parseTracksFromPlaylist(data)
    }

    // MARK: - HTTP

    private func ytmRequest(endpoint: String, body: [String: Any]) async throws -> Data {
        let url = URL(string: "https://music.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")

        // Only send .youtube.com cookies — a real browser never mixes .google.com
        // cookies into requests to music.youtube.com. Sending both causes yt_li=0.
        let ytCookies = authCookies.filter { $0.domain.hasSuffix(".youtube.com") || $0.domain == "youtube.com" }
        let cookieStr = ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        request.setValue(cookieStr, forHTTPHeaderField: "Cookie")
        print("[YTM] yt cookies: \(ytCookies.map(\.name).joined(separator: ", "))")

        // SAPISIDHASH — use the .youtube.com SAPISID so it matches the Cookie header
        let sapisid = ytCookies.first(where: { $0.name == "SAPISID" })?.value
                   ?? ytCookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value
                   ?? authCookies.first(where: { $0.name == "SAPISID" })?.value
        if let sapisid {
            request.setValue(generateSAPISIDHASH(sapisid: sapisid), forHTTPHeaderField: "Authorization")
            print("[YTM] SAPISIDHASH using: \(sapisid.prefix(8))…")
        } else {
            print("[YTM] WARNING: no SAPISID found — auth will fail")
        }

        // Wrap body in standard YouTube Music context
        var fullBody = body
        fullBody["context"] = ytmContext()

        request.httpBody = try JSONSerialization.data(withJSONObject: fullBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Opportunistically grab visitorData from every response
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ctx = json["responseContext"] as? [String: Any],
           let vd = ctx["visitorData"] as? String, !vd.isEmpty, visitorData.isEmpty {
            visitorData = vd
            print("[YTM] visitorData from response: \(vd.prefix(16))…")
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[YTM] \(status) on \(endpoint) — \(body.prefix(400))")
            throw YTMError.httpError(status)
        }
        return data
    }

    private func generateSAPISIDHASH(sapisid: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)
        let message = "\(timestamp) \(sapisid) https://music.youtube.com"
        let digest = Insecure.SHA1.hash(data: Data(message.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    private func cookieHeader() -> String {
        authCookies
            .filter { $0.domain.hasSuffix(".youtube.com") || $0.domain == "youtube.com" }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    func cookieHeaderForYouTube() -> String? {
        var cookieMap: [String: String] = [:]
        for c in authCookies where c.domain.hasSuffix(".youtube.com") || c.domain == "youtube.com" {
            cookieMap[c.name] = c.value
        }
        for c in sessionCookies { cookieMap[c.name] = c.value }
        let header = cookieMap.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }

    private func ytmContext() -> [String: Any] {
        let datePart = {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date())
        }()
        var client: [String: Any] = [
            "clientName": "WEB_REMIX",
            "clientVersion": "1.\(datePart).01.00",
            "hl": "en",
            "gl": "US",
            "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36,gzip(gfe)"
        ]
        if !visitorData.isEmpty { client["visitorData"] = visitorData }
        return [
            "client": client,
            "user": ["lockedSafetyMode": false],
            "request": ["useSsl": true, "internalExperimentFlags": [Any]()]
        ]
    }

    // MARK: - Audio streaming (JavaScriptCore — handles 2025 player cipher + n-param)

    private var jsContextCache: (playerPath: String, context: JSContext)?
    private var sessionCookies: [HTTPCookie] = []

    func fetchAudioStreamURL(videoId: String) async throws -> URL {
        // 1. Get player JS path from watch page (fast; needed for JSContext + STS)
        let html = await fetchWatchPageHTML(videoId: videoId)
        var playerPath = extractPlayerJSPath(from: html)

        // Fallback: try embed page if watch page didn't yield player JS
        if playerPath == nil {
            print("[YTM] trying embed page fallback for player JS")
            let embedHTML = await fetchEmbedPageHTML(videoId: videoId)
            playerPath = extractPlayerJSPath(from: embedHTML)
        }

        // 2. Build JSContext — fetches+parses player JS, extracts STS and cipher fns.
        //    STS (signatureTimestamp) must be sent to the player API or it returns
        //    format metadata only (no url / signatureCipher fields).
        let ctx = try await getJSContext(playerPath: playerPath)
        let sts = ctx.objectForKeyedSubscript("__ytSTS")?.toInt32() ?? 0
        print("[YTM] STS=\(sts)")

        // 3. Try alternate clients — ANDROID_VR first (no cipher/n-param/po_token needed)
        for clientName in ["ANDROID_VR", "MWEB", "WEB_CREATOR"] {
            if let altURL = try? await fetchDirectURLViaClient(clientName, videoId: videoId, ctx: ctx) {
                return altURL
            }
        }
        print("[YTM] all alternate clients failed, trying WEB+cipher")

        // 4. WEB client with STS — may return signatureCipher
        let playerJSON = try await fetchPlayerAPIData(videoId: videoId, sts: Int(sts))

        // Playability check
        if let ps = playerJSON["playabilityStatus"] as? [String: Any],
           let status = ps["status"] as? String, status != "OK" {
            throw YTMError.parseError("not playable: \(ps["reason"] as? String ?? status)")
        }
        guard let sd = playerJSON["streamingData"] as? [String: Any] else {
            throw YTMError.parseError("no streamingData in player API response")
        }

        // 4. Collect audio formats — prefer mp4 (AAC) over webm (opus) for Apple playback
        let candidates = (sd["adaptiveFormats"] as? [[String: Any]] ?? [])
                       + (sd["formats"] as? [[String: Any]] ?? [])
        let audioFmts = candidates
            .filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/") }
            .sorted { lhs, rhs in
                let lMime = (lhs["mimeType"] as? String ?? "")
                let rMime = (rhs["mimeType"] as? String ?? "")
                let lMp4 = lMime.hasPrefix("audio/mp4")
                let rMp4 = rMime.hasPrefix("audio/mp4")
                if lMp4 != rMp4 { return lMp4 }
                return (lhs["bitrate"] as? Int ?? 0) > (rhs["bitrate"] as? Int ?? 0)
            }

        print("[YTM] audio formats: \(audioFmts.prefix(4).map { "\(($0["mimeType"] as? String ?? "?").prefix(20)) @ \($0["bitrate"] as? Int ?? 0)bps" })")

        guard !audioFmts.isEmpty else {
            throw YTMError.parseError("no audio formats in player response")
        }

        // 4a. Direct URL — use String cast (guards against JSON null / NSNull)
        if let best = audioFmts.first(where: { ($0["url"] as? String) != nil }),
           let urlStr = best["url"] as? String {
            let final = decodeNParam(urlStr, ctx: ctx)
            if let u = makeURL(final) {
                print("[YTM] direct stream itag=\(best["itag"] ?? "?")")
                return u
            }
            print("[YTM] direct URL construction failed, falling through")
        }

        // 4b. signatureCipher / cipher — again use String cast to skip NSNull values
        let cipherKey: String
        if audioFmts.contains(where: { ($0["signatureCipher"] as? String) != nil }) {
            cipherKey = "signatureCipher"
        } else if audioFmts.contains(where: { ($0["cipher"] as? String) != nil }) {
            cipherKey = "cipher"
        } else {
            // Log the actual keys so future debugging is instant
            let keys = audioFmts.flatMap { Array($0.keys) }
            print("[YTM] audio fmt known keys: \(Set(keys).sorted())")
            throw YTMError.parseError("no usable audio format (no url / signatureCipher / cipher)")
        }
        guard let best = audioFmts.first(where: { ($0[cipherKey] as? String) != nil }),
              let cipherStr = best[cipherKey] as? String else {
            throw YTMError.parseError("cipher key '\(cipherKey)' found but value is not a string")
        }

        var cp: [String: String] = [:]
        for part in cipherStr.components(separatedBy: "&") {
            let kv = part.components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            cp[kv[0]] = kv.dropFirst().joined(separator: "=").removingPercentEncoding ?? ""
        }
        guard let baseURL = cp["url"], let encSig = cp["s"] else {
            throw YTMError.parseError("cipher missing url or s param")
        }
        let sigParam = cp["sp"] ?? "sig"

        // 5. Decode sig using already-built JSContext (ctx from step 2, reused)
        guard let sigFnName = ctx.objectForKeyedSubscript("__ytSigFnName")?.toString(),
              !sigFnName.isEmpty, sigFnName != "undefined" else {
            throw YTMError.parseError("sig function name not in JSContext")
        }
        guard let decodedSig = ctx.evaluateScript("\(sigFnName)(\(jsQuote(encSig)))")?.toString(),
              !decodedSig.isEmpty, decodedSig != "undefined" else {
            throw YTMError.parseError("sig decoding failed")
        }

        let sep = baseURL.contains("?") ? "&" : "?"
        let siggedURL = "\(baseURL)\(sep)\(sigParam)=\(decodedSig)"

        // 6. Decode n-parameter (causes HTTP 403 if wrong)
        let final = decodeNParam(siggedURL, ctx: ctx)
        guard let finalURL = makeURL(final) else {
            throw YTMError.parseError("could not build final URL")
        }
        print("[YTM] cipher+n decoded itag=\(best["itag"] ?? "?")")
        return finalURL
    }

    // URL construction tolerant of unencoded | characters that YouTube includes in fexp params
    private func makeURL(_ s: String) -> URL? {
        if let u = URL(string: s) { return u }
        let cleaned = s.replacingOccurrences(of: "|", with: "%7C")
                       .replacingOccurrences(of: " ", with: "%20")
        return URL(string: cleaned)
    }

    private func fetchWatchPageHTML(videoId: String) async -> String {
        let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1")!
        var r = URLRequest(url: url)
        var cookies = cookieHeader()
        if !cookies.contains("SOCS=") { cookies += (cookies.isEmpty ? "" : "; ") + "SOCS=CAI" }
        r.setValue(cookies, forHTTPHeaderField: "Cookie")
        r.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, resp) = try? await session.data(for: r),
              let html = String(data: data, encoding: .utf8) else { return "" }
        if let httpResp = resp as? HTTPURLResponse {
            var captured: [HTTPCookie] = []
            if let headerFields = httpResp.allHeaderFields as? [String: String] {
                captured = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            }
            if captured.isEmpty, let setCookies = httpResp.value(forHTTPHeaderField: "Set-Cookie") {
                let synthetic = ["Set-Cookie": setCookies]
                captured = HTTPCookie.cookies(withResponseHeaderFields: synthetic, for: url)
            }
            if !captured.isEmpty {
                sessionCookies = captured
                let names = captured.map(\.name).joined(separator: ", ")
                print("[YTM] captured \(captured.count) session cookies: \(names)")
            } else {
                print("[YTM] no session cookies in watch page response")
            }
        }
        return html
    }

    private func fetchEmbedPageHTML(videoId: String) async -> String {
        let url = URL(string: "https://www.youtube.com/embed/\(videoId)")!
        var r = URLRequest(url: url)
        r.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        guard let (data, _) = try? await URLSession.shared.data(for: r),
              let html = String(data: data, encoding: .utf8) else { return "" }
        return html
    }

    private func fetchPlayerAPIData(videoId: String, sts: Int = 0) async throws -> [String: Any] {
        let url = URL(string: "https://www.youtube.com/youtubei/v1/player")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let ytCookies = authCookies.filter { $0.domain.hasSuffix(".youtube.com") || $0.domain == "youtube.com" }
        req.setValue(ytCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")

        // SAPISIDHASH for www.youtube.com origin
        let sapisid = ytCookies.first(where: { $0.name == "SAPISID" })?.value
                   ?? ytCookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value
                   ?? authCookies.first(where: { $0.name == "SAPISID" })?.value
        if let sapisid {
            let ts = Int(Date().timeIntervalSince1970)
            let msg = "\(ts) \(sapisid) https://www.youtube.com"
            let digest = Insecure.SHA1.hash(data: Data(msg.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            req.setValue("SAPISIDHASH \(ts)_\(hex)", forHTTPHeaderField: "Authorization")
        }

        let datePart = { () -> String in
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.timeZone = TimeZone(identifier: "UTC")
            return f.string(from: Date())
        }()
        var webClientDict: [String: Any] = [
            "clientName": "WEB",
            "clientVersion": "2.\(datePart).01.00",
            "hl": "en",
            "gl": "US",
            "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36,gzip(gfe)"
        ]
        if !visitorData.isEmpty { webClientDict["visitorData"] = visitorData }
        let body: [String: Any] = [
            "videoId": videoId,
            "context": ["client": webClientDict],
            "playbackContext": [
                "contentPlaybackContext": ({
                    var ctx: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
                    if sts > 0 { ctx["signatureTimestamp"] = sts }
                    return ctx
                }())
            ],
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        print("[YTM] player API status=\(status)")
        guard status == 200 else {
            print("[YTM] player API body: \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")")
            throw YTMError.httpError(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid player API response")
        }
        return json
    }

    private func decodeNParam(_ urlStr: String, ctx: JSContext) -> String {
        guard var comps = URLComponents(string: urlStr),
              let nItem = comps.queryItems?.first(where: { $0.name == "n" }),
              let encN = nItem.value, !encN.isEmpty else { return urlStr }

        guard let nFnName = ctx.objectForKeyedSubscript("__ytNFnName")?.toString(),
              !nFnName.isEmpty, nFnName != "undefined" else {
            print("[YTM] no n-fn, skipping n decode")
            return urlStr
        }
        guard let decodedN = ctx.evaluateScript("\(nFnName)(\(jsQuote(encN)))")?.toString(),
              !decodedN.isEmpty, decodedN != "undefined" else {
            print("[YTM] n decode failed, using original")
            return urlStr
        }
        var items = comps.queryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "n" }) {
            items[idx] = URLQueryItem(name: "n", value: decodedN)
        }
        comps.queryItems = items
        return comps.url?.absoluteString ?? urlStr
    }

    // Try alternate player clients that return direct (non-ciphered) stream URLs.
    private func fetchDirectURLViaClient(_ clientName: String, videoId: String, ctx: JSContext) async throws -> URL {
        let apiURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")

        let datePart: String = {
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd"
            f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: Date())
        }()

        var clientDict: [String: Any]
        var contextExtra: [String: Any] = [:]
        var needsAuth = true

        switch clientName {
        case "ANDROID_VR":
            let vrUA = "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"
            req.setValue(vrUA, forHTTPHeaderField: "User-Agent")
            req.setValue("28", forHTTPHeaderField: "X-Youtube-Client-Name")
            req.setValue("1.65.10", forHTTPHeaderField: "X-Youtube-Client-Version")
            if !visitorData.isEmpty {
                req.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
            }
            needsAuth = false
            clientDict = [
                "clientName": "ANDROID_VR",
                "clientVersion": "1.65.10",
                "deviceMake": "Oculus",
                "deviceModel": "Quest 3",
                "osName": "Android",
                "osVersion": "12L",
                "androidSdkVersion": 32,
                "userAgent": vrUA,
                "hl": "en",
                "timeZone": "UTC",
                "utcOffsetMinutes": 0
            ]

        case "MWEB":
            let mUA = "Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36"
            req.setValue(mUA, forHTTPHeaderField: "User-Agent")
            clientDict = ["clientName": "MWEB", "clientVersion": "2.\(datePart).01.00", "hl": "en", "gl": "US", "userAgent": mUA]

        case "WEB_CREATOR":
            let wcUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            req.setValue(wcUA, forHTTPHeaderField: "User-Agent")
            clientDict = ["clientName": "WEB_CREATOR", "clientVersion": "1.\(datePart).01.00", "hl": "en", "gl": "US", "userAgent": wcUA]

        default: // WEB_EMBEDDED_PLAYER
            let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            req.setValue(webUA, forHTTPHeaderField: "User-Agent")
            clientDict = ["clientName": "WEB_EMBEDDED_PLAYER", "clientVersion": "1.\(datePart)", "hl": "en", "gl": "US", "userAgent": webUA]
            contextExtra = ["thirdParty": ["embedUrl": "https://google.com"]]
        }

        if needsAuth {
            req.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")

            let ytCookies = authCookies.filter { $0.domain.hasSuffix(".youtube.com") || $0.domain == "youtube.com" }
            var cookieMap: [String: String] = [:]
            for c in ytCookies { cookieMap[c.name] = c.value }
            for c in sessionCookies { cookieMap[c.name] = c.value }
            req.setValue(cookieMap.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")

            let sapisid = ytCookies.first(where: { $0.name == "SAPISID" })?.value
                       ?? ytCookies.first(where: { $0.name == "__Secure-3PAPISID" })?.value
                       ?? authCookies.first(where: { $0.name == "SAPISID" })?.value
            if let sapisid {
                let ts = Int(Date().timeIntervalSince1970)
                let msg = "\(ts) \(sapisid) https://www.youtube.com"
                let digest = Insecure.SHA1.hash(data: Data(msg.utf8))
                let hex = digest.map { String(format: "%02x", $0) }.joined()
                req.setValue("SAPISIDHASH \(ts)_\(hex)", forHTTPHeaderField: "Authorization")
            }

            if !visitorData.isEmpty { clientDict["visitorData"] = visitorData }
        }

        var contextDict: [String: Any] = ["client": clientDict]
        for (k, v) in contextExtra { contextDict[k] = v }

        var body: [String: Any] = [
            "videoId": videoId,
            "context": contextDict,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]
        var playbackCtx: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if needsAuth {
            let sts = ctx.objectForKeyedSubscript("__ytSTS")?.toInt32() ?? 0
            if sts > 0 { playbackCtx["signatureTimestamp"] = sts }
        }
        body["playbackContext"] = ["contentPlaybackContext": playbackCtx]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[YTM][\(clientName)] auth=\(needsAuth) body: \(String(data: req.httpBody!, encoding: .utf8)?.prefix(600) ?? "")")

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            print("[YTM][\(clientName)] \(status): \(String(data: data, encoding: .utf8)?.prefix(400) ?? "")")
            throw YTMError.httpError(status)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("\(clientName): invalid response")
        }

        let psDict = json["playabilityStatus"] as? [String: Any]
        let psStatus = psDict?["status"] as? String ?? "unknown"
        let psReason = psDict?["reason"] as? String ?? ""
        let hasSD = json["streamingData"] != nil
        print("[YTM][\(clientName)] playability=\(psStatus)\(psReason.isEmpty ? "" : "(\(psReason))") hasSD=\(hasSD)")

        guard psStatus == "OK" else {
            throw YTMError.parseError("\(clientName) not playable: \(psStatus)")
        }
        guard let sd = json["streamingData"] as? [String: Any] else {
            throw YTMError.parseError("\(clientName): no streamingData")
        }

        let candidates = (sd["adaptiveFormats"] as? [[String: Any]] ?? [])
                       + (sd["formats"] as? [[String: Any]] ?? [])
        let audioFmts = candidates
            .filter { ($0["mimeType"] as? String ?? "").hasPrefix("audio/") }
            .sorted { lhs, rhs in
                let lMp4 = ((lhs["mimeType"] as? String) ?? "").hasPrefix("audio/mp4")
                let rMp4 = ((rhs["mimeType"] as? String) ?? "").hasPrefix("audio/mp4")
                if lMp4 != rMp4 { return lMp4 }
                return (lhs["bitrate"] as? Int ?? 0) > (rhs["bitrate"] as? Int ?? 0)
            }

        let hasDirect = audioFmts.contains { ($0["url"] as? String) != nil }
        let hasCipher = audioFmts.contains { ($0["signatureCipher"] as? String) != nil }
        if let firstKeys = audioFmts.first.map({ Array($0.keys).sorted() }) {
            print("[YTM][\(clientName)] fmts=\(audioFmts.count) direct=\(hasDirect) cipher=\(hasCipher) keys=\(firstKeys.prefix(5))")
        }

        // Prefer direct URL; fall back to signatureCipher decode if we have a working sig fn
        if let best = audioFmts.first(where: { ($0["url"] as? String) != nil }),
           let urlStr = best["url"] as? String {
            let final = decodeNParam(urlStr, ctx: ctx)
            if let u = makeURL(final) {
                print("[YTM][\(clientName)] ✓ direct itag=\(best["itag"] ?? "?")")
                return u
            }
        }

        // signatureCipher decode path (MWEB, WEB_CREATOR, etc.)
        if hasCipher,
           let sigFnName = ctx.objectForKeyedSubscript("__ytSigFnName")?.toString(),
           !sigFnName.isEmpty, sigFnName != "undefined",
           let best = audioFmts.first(where: { ($0["signatureCipher"] as? String) != nil }),
           let cipherStr = best["signatureCipher"] as? String {
            var cp: [String: String] = [:]
            for part in cipherStr.components(separatedBy: "&") {
                let kv = part.components(separatedBy: "=")
                guard kv.count >= 2 else { continue }
                cp[kv[0]] = kv.dropFirst().joined(separator: "=").removingPercentEncoding ?? ""
            }
            if let baseURL = cp["url"], let encSig = cp["s"],
               let decodedSig = ctx.evaluateScript("\(sigFnName)(\(jsQuote(encSig)))")?.toString(),
               !decodedSig.isEmpty, decodedSig != "undefined" {
                let sigParam = cp["sp"] ?? "sig"
                let sep = baseURL.contains("?") ? "&" : "?"
                let siggedURL = "\(baseURL)\(sep)\(sigParam)=\(decodedSig)"
                let final = decodeNParam(siggedURL, ctx: ctx)
                if let u = makeURL(final) {
                    print("[YTM][\(clientName)] ✓ cipher itag=\(best["itag"] ?? "?")")
                    return u
                }
            }
            print("[YTM][\(clientName)] cipher decode failed (sig fn '\(sigFnName)' returned nil)")
        }

        throw YTMError.parseError("\(clientName): no usable URL (direct=\(hasDirect) cipher=\(hasCipher))")
    }

    private func getJSContext(playerPath: String?) async throws -> JSContext {
        let path = playerPath ?? ""
        if !path.isEmpty, let cached = jsContextCache, cached.playerPath == path {
            return cached.context
        }
        guard !path.isEmpty else { throw YTMError.parseError("player JS path not found") }
        guard let jsURL = URL(string: "https://www.youtube.com\(path)"),
              let (jsData, _) = try? await URLSession.shared.data(from: jsURL),
              let js = String(data: jsData, encoding: .utf8) else {
            throw YTMError.parseError("failed to fetch player JS")
        }
        let ctx = try buildJSContext(from: js)
        jsContextCache = (path, ctx)
        return ctx
    }

    // Strategy B: find sig function via the helper object that contains cipher operations.
    private func findSigFnViaHelperObject(in js: String) -> String? {
        // Try multiple patterns for the splice method inside the helper object.
        // 2025 Closure Compiler may use different variable name styles.
        let splicePatterns = [
            // Standard: METHOD:function(a,b){a.splice(0,b)}
            #"([a-zA-Z_$][\w$]*)\s*:\s*function\s*\(\s*[a-zA-Z_$][\w$]*\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*\{\s*[a-zA-Z_$][\w$]*\.splice\s*\(\s*0\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*\}"#,
            // Arrow function: METHOD:(a,b)=>{a.splice(0,b)}
            #"([a-zA-Z_$][\w$]*)\s*:\s*\(\s*[a-zA-Z_$][\w$]*\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*=>\s*\{\s*[a-zA-Z_$][\w$]*\.splice\s*\(\s*0\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*\}"#,
            // Concise: METHOD(a,b){a.splice(0,b)}
            #"([a-zA-Z_$][\w$]*)\s*\(\s*[a-zA-Z_$][\w$]*\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*\{\s*[a-zA-Z_$][\w$]*\.splice\s*\(\s*0\s*,\s*[a-zA-Z_$][\w$]*\s*\)\s*\}"#,
        ]
        var spliceMethodRange: Range<String.Index>?
        for pat in splicePatterns {
            if let re = try? NSRegularExpression(pattern: pat),
               let m = re.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
               let r = Range(m.range(at: 0), in: js) {
                spliceMethodRange = r
                print("[YTM] splice method found via: \(pat.prefix(50))")
                break
            }
        }
        guard let spliceRange = spliceMethodRange else {
            print("[YTM] helper splice method not found in any format")
            return nil
        }

        // Scan backward to find the `var NAME={` containing this method
        let prefix = String(js[js.startIndex..<spliceRange.lowerBound])
        let varObjPat = #"var\s+([a-zA-Z_$][\w$]*)\s*=\s*\{"#
        var helperName = ""
        if let varRe = try? NSRegularExpression(pattern: varObjPat) {
            let allVarMatches = varRe.matches(in: prefix, range: NSRange(prefix.startIndex..., in: prefix))
            if let lastVar = allVarMatches.last,
               let nameRange = Range(lastVar.range(at: 1), in: prefix) {
                helperName = String(prefix[nameRange])
            }
        }
        guard !helperName.isEmpty else {
            print("[YTM] helper object var name not found (no var NAME={ before splice)")
            return nil
        }
        print("[YTM] helper obj: '\(helperName)'")

        // Find the sig function: calls methods on helperName
        let escapedHelper = NSRegularExpression.escapedPattern(for: helperName)
        let sigFromHelperPat = "([a-zA-Z_$][\\w$]*)\\s*=\\s*function\\s*\\([a-zA-Z_$][\\w$]*\\)\\s*\\{[^}]*\\b\(escapedHelper)\\s*[\\[\\.]"
        guard let sigRe = try? NSRegularExpression(pattern: sigFromHelperPat),
              let sigMatch = sigRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
              let sigNameRange = Range(sigMatch.range(at: 1), in: js) else {
            print("[YTM] sig fn not found via helper '\(helperName)'")
            return nil
        }
        let name = String(js[sigNameRange])
        print("[YTM] sig fn '\(name)' via helper obj '\(helperName)'")
        return name
    }

    private func buildJSContext(from js: String) throws -> JSContext {
        guard let ctx = JSContext() else { throw YTMError.parseError("JSContext() returned nil") }
        ctx.exceptionHandler = { _, ex in print("[YTM][JS] \(ex?.toString() ?? "nil")") }
        print("[YTM] player JS size=\(js.count) chars")

        var sigScript = ""  // the sig-decode snippet to inject
        var sigFnName = ""

        // ── Strategy 1: 2025 dispatch-table style ─────────────────────────────
        // The 2025 player stores method names in var UVAR="a{b{c{...".split("{"),
        // defines a helper object with splice/swap/reverse via UVAR[N],
        // and runs cipher through FN1(R1,H1,FN2(R2,H2,s)).
        // All names are minified per build — extract from the cipher call site.
        let callGenPat = #"([a-zA-Z_$][\w$]*)\((\d+),(\d+),([a-zA-Z_$][\w$]*)\((\d+),(\d+),\w+\.s\)\)"#
        let uGenPat    = #"var ([a-zA-Z_$][\w$]*)="([^"]*\{[^"]*\{[^"]*\{[^"]{10,})""#

        if let callRe = try? NSRegularExpression(pattern: callGenPat),
           let callM  = callRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
           let fn1R = Range(callM.range(at: 1), in: js),
           let r1R  = Range(callM.range(at: 2), in: js), let h1R = Range(callM.range(at: 3), in: js),
           let fn2R = Range(callM.range(at: 4), in: js),
           let r2R  = Range(callM.range(at: 5), in: js), let h2R = Range(callM.range(at: 6), in: js),
           let uRe  = try? NSRegularExpression(pattern: uGenPat),
           let uM   = uRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
           let uVarR = Range(uM.range(at: 1), in: js), let uStrR = Range(uM.range(at: 2), in: js) {

            let fn1 = String(js[fn1R]); let fn2 = String(js[fn2R])
            let r1  = String(js[r1R]);  let h1  = String(js[h1R])
            let r2  = String(js[r2R]);  let h2  = String(js[h2R])
            let uVar = String(js[uVarR]); let uStr = String(js[uStrR])

            print("[YTM] cipher call: \(fn1)(\(r1),\(h1),\(fn2)(\(r2),\(h2),s)) uVar=\(uVar)")

            // Extract fn1 and fn2 — require 3+ params to skip unrelated same-name functions
            let fn1Src = extractFunctionDef(named: fn1, from: js, minParamCount: 3) ?? ""
            let fn2Src = extractFunctionDef(named: fn2, from: js, minParamCount: 3) ?? ""

            // Find helper object: var HELPER={...} referenced inside fn1 body as HELPER[UVAR[...]]
            var helperBlock = ""
            let escapedU = NSRegularExpression.escapedPattern(for: uVar)
            let helperRefPat = "([a-zA-Z_$][\\w$]+)\\[\(escapedU)\\["
            if let helperRefRe = try? NSRegularExpression(pattern: helperRefPat) {
                var seen = Set<String>()
                for m in helperRefRe.matches(in: fn1Src, range: NSRange(fn1Src.startIndex..., in: fn1Src)) {
                    guard let r = Range(m.range(at: 1), in: fn1Src) else { continue }
                    let name = String(fn1Src[r])
                    guard seen.insert(name).inserted else { continue }
                    if let hSrc = extractVarObject(named: name, from: js) {
                        helperBlock = hSrc
                        print("[YTM] helper: \(name)")
                        break
                    }
                }
            }

            if !fn1Src.isEmpty && !fn2Src.isEmpty {
                sigFnName = "__ytDecodeSig"
                var parts = "var \(uVar)=\"\(uStr)\".split(\"{\");\n"
                if !helperBlock.isEmpty { parts += helperBlock + ";\n" }
                parts += fn2Src + ";\n"
                parts += fn1Src + ";\n"
                parts += "function __ytDecodeSig(s){return \(fn1)(\(r1),\(h1),\(fn2)(\(r2),\(h2),s));}\n"
                sigScript = parts
                print("[YTM] cipher: 2025 dispatch-table \(fn1)/\(fn2)/\(uVar)")
            }
        }

        // ── Strategy 2: classic split/reverse/splice helper (pre-2025) ───────
        if sigFnName.isEmpty {
            sigFnName = findSigFnViaHelperObject(in: js) ?? ""

            if sigFnName.isEmpty {
                // Call-site patterns
                let callSitePatterns: [(String, Int)] = [
                    (#"\bm\s*=\s*([a-zA-Z0-9$]{2,})\s*\(\s*decodeURIComponent\s*\(\s*h\.s\s*\)\s*\)"#, 1),
                    (#"\.set\s*\([^,]+,\s*encodeURIComponent\s*\(\s*([a-zA-Z0-9$]{2,})\s*\("#, 1),
                    (#"\.sig\s*\|\|\s*([a-zA-Z0-9$_]{2,})\s*\("#, 1),
                    (#"\.set\s*\([^,]*\|\|\"sig\",\s*(?:encodeURIComponent\s*\(\s*)?([a-zA-Z0-9$_]{2,})\s*\("#, 1),
                    (#"\.set\s*\([^,]+,\s*([a-zA-Z0-9$_]{2,})\s*\([a-zA-Z0-9$_]+\.s\b"#, 1),
                    (#"\b([a-zA-Z_$][\w$]*)&&\(\1=([a-zA-Z_$][\w$]{1,})\s*\("#, 2),
                ]
                let singleLetters: Set<String> = ["a","b","c","d","e","f","g","h","i","j","k","l","m","n"]
                for (pat, group) in callSitePatterns {
                    guard let re = try? NSRegularExpression(pattern: pat),
                          let m = re.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
                          let r = Range(m.range(at: group), in: js) else { continue }
                    let candidate = String(js[r])
                    if !singleLetters.contains(candidate) {
                        sigFnName = candidate
                        print("[YTM] sig fn '\(sigFnName)' via call-site pattern")
                        break
                    }
                }
            }

            if !sigFnName.isEmpty, let fnSrc = extractFunctionDef(named: sigFnName, from: js) {
                // Find helper object via broad IDENTIFIER. scan
                let helperScanPat = #"\b([a-zA-Z_$][\w$]{1,})\.[a-zA-Z_$]"#
                var helperSrc = ""
                if let helperScanRe = try? NSRegularExpression(pattern: helperScanPat) {
                    var seen = Set<String>(); var candidates: [String] = []
                    for m in helperScanRe.matches(in: fnSrc, range: NSRange(fnSrc.startIndex..., in: fnSrc)) {
                        if let r = Range(m.range(at: 1), in: fnSrc) {
                            let name = String(fnSrc[r])
                            if seen.insert(name).inserted { candidates.append(name) }
                        }
                    }
                    for cand in candidates {
                        if let hSrc = extractVarObject(named: cand, from: js) { helperSrc = hSrc; break }
                    }
                }
                if !helperSrc.isEmpty {
                    sigScript = helperSrc + ";\n" + fnSrc + ";\n"
                    print("[YTM] cipher: classic helper+sigfn '\(sigFnName)'")
                } else {
                    print("[YTM] WARNING: classic helper not found for '\(sigFnName)'")
                    sigFnName = ""
                }
            } else if !sigFnName.isEmpty {
                print("[YTM] WARNING: body of sig fn '\(sigFnName)' not found")
                sigFnName = ""
            } else {
                print("[YTM] WARNING: sig fn not found in player JS")
            }
        }

        // ── n-throttle function ───────────────────────────────────────────────
        var nFnName = ""
        // Array variant: .get("n"))&&(VAR=ARRAY[IDX](VAR)
        let nArrPat = #"\.get\("n"\)\)&&\([a-zA-Z_$][\w$]*=([a-zA-Z_$][\w$]*)\[(\d+)\]\([a-zA-Z_$][\w$]*\)"#
        if let nArrRe = try? NSRegularExpression(pattern: nArrPat),
           let m = nArrRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
           let arrNameR = Range(m.range(at: 1), in: js),
           let arrIdxR  = Range(m.range(at: 2), in: js) {
            let arrName = String(js[arrNameR])
            let arrIdx  = Int(String(js[arrIdxR])) ?? 0
            let arrPat  = "var \(NSRegularExpression.escapedPattern(for: arrName))=\\[([^\\]]+)\\]"
            if let arrRe = try? NSRegularExpression(pattern: arrPat),
               let am = arrRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
               let cr = Range(am.range(at: 1), in: js) {
                let parts = String(js[cr]).components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                if arrIdx < parts.count { nFnName = parts[arrIdx] }
            }
        }
        if nFnName.isEmpty {
            let nDirPat = #"\.get\("n"\)\)&&\([a-zA-Z_$][\w$]*=([a-zA-Z_$][\w$]*)\([a-zA-Z_$][\w$]*\)"#
            if let nDirRe = try? NSRegularExpression(pattern: nDirPat),
               let m = nDirRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
               let r = Range(m.range(at: 1), in: js) {
                nFnName = String(js[r])
            }
        }
        var nFnSrc = ""
        if !nFnName.isEmpty, let src = extractFunctionDef(named: nFnName, from: js) {
            nFnSrc = src; print("[YTM] n-fn: \(nFnName)")
        } else {
            print("[YTM] n-fn not found (expected for 2025+ players)")
        }

        // ── STS ──────────────────────────────────────────────────────────────
        var stsValue = 0
        let stsPat = #"signatureTimestamp\s*:\s*(\d+)"#
        if let stsRe = try? NSRegularExpression(pattern: stsPat),
           let stsM = stsRe.firstMatch(in: js, range: NSRange(js.startIndex..., in: js)),
           let stsR = Range(stsM.range(at: 1), in: js) {
            stsValue = Int(String(js[stsR])) ?? 0
        }

        // ── Inject into JSContext ─────────────────────────────────────────────
        var script = sigScript
        script += "var __ytSigFnName=\"\(sigFnName)\";\n"
        script += "var __ytSTS=\(stsValue);\n"
        if !nFnSrc.isEmpty {
            script += nFnSrc + ";\n"
            script += "var __ytNFnName=\"\(nFnName)\";\n"
        } else {
            script += "var __ytNFnName=\"\";\n"
        }
        ctx.evaluateScript(script)
        print("[YTM] JSContext ready: sig=\(sigFnName.isEmpty ? "none" : sigFnName) n=\(nFnName.isEmpty ? "none" : nFnName) sts=\(stsValue)")
        return ctx
    }

    // Brace-balanced block extraction starting at a `{`
    private func extractBraceBlock(from s: String, startingAt start: String.Index) -> String {
        var depth = 0, inStr = false, strChar: Character = "\"", esc = false, end = start
        for idx in s[start...].indices {
            let c = s[idx]
            if esc { esc = false; continue }
            if c == "\\" && inStr { esc = true; continue }
            if inStr { if c == strChar { inStr = false }; continue }
            if c == "\"" || c == "'" { inStr = true; strChar = c; continue }
            if c == "{" { depth += 1 }
            else if c == "}" { depth -= 1; if depth == 0 { end = s.index(after: idx); break } }
        }
        return String(s[start..<end])
    }

    // Extracts `var/let/const NAME={...}` or bare `NAME={...}` using brace matching
    private func extractVarObject(named name: String, from js: String) -> String? {
        for prefix in ["var \(name)={", "let \(name)={", "const \(name)={", ";\(name)={", ",\(name)={"] {
            if let r = js.range(of: prefix) {
                let braceStart = js.index(r.upperBound, offsetBy: -1)
                let block = extractBraceBlock(from: js, startingAt: braceStart)
                return "var \(name)=\(block)"
            }
        }
        return nil
    }

    // Extracts `NAME=function(...){...}` or `var NAME=function(...){...}` using brace matching.
    // When minParamCount > 0, skips definitions with fewer parameters (handles
    // 2025 players where a name like `xt` has 18 definitions but the cipher one has 3+ params).
    private func extractFunctionDef(named name: String, from js: String, minParamCount: Int = 0) -> String? {
        for prefix in ["\(name)=function(", "var \(name)=function("] {
            var searchStart = js.startIndex
            while let pr = js.range(of: prefix, range: searchStart..<js.endIndex) {
                guard let parenClose = js[pr.upperBound...].firstIndex(of: ")"),
                      let braceIdx = js[parenClose...].firstIndex(of: "{") else {
                    searchStart = pr.upperBound; continue
                }
                if minParamCount > 0 {
                    let paramStr = String(js[pr.upperBound..<parenClose])
                    let paramCount = paramStr.isEmpty ? 0 : paramStr.components(separatedBy: ",").count
                    if paramCount < minParamCount {
                        searchStart = pr.upperBound; continue
                    }
                }
                let block = extractBraceBlock(from: js, startingAt: braceIdx)
                return String(js[pr.lowerBound..<braceIdx]) + block
            }
        }
        return nil
    }

    private func extractPlayerJSPath(from html: String) -> String? {
        let patterns = [
            #""PLAYER_JS_URL"\s*:\s*"(/s/player/[^"]+\.js)""#,
            #""jsUrl"\s*:\s*"(/s/player/[^"]+\.js)""#,
            #"src="(/s/player/[^"]+\.js)""#,
            #""PLAYER_JS_URL"\s*:\s*"(\\?/s\\?/player\\?/[^"]+\.js)""#,
            #""jsUrl"\s*:\s*"(\\?/s\\?/player\\?/[^"]+\.js)""#,
            #"/s/player/[a-zA-Z0-9]+/player_ias\.vflset/[a-z_]+/base\.js"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m  = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                let captureIdx = m.numberOfRanges > 1 ? 1 : 0
                if let r = Range(m.range(at: captureIdx), in: html) {
                    let raw = String(html[r])
                    let cleaned = raw.replacingOccurrences(of: "\\/", with: "/")
                    print("[YTM] player JS path: \(cleaned) (pattern \(patterns.firstIndex(of: p) ?? -1))")
                    return cleaned
                }
            }
        }
        print("[YTM] player JS path not found in HTML (\(html.count) chars)")
        if html.count < 500 {
            print("[YTM] short HTML dump: \(html)")
        }
        return nil
    }

    private func jsQuote(_ s: String) -> String {
        let esc = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(esc)\""
    }

    // MARK: - Parsing

    // Parse album from musicResponsiveListItemRenderer (used in search results for albums)
    private func parseAlbumFromResponsiveRenderer(_ r: [String: Any]) -> Playlist? {
        // Check if this item navigates to an album browse page
        var browseId: String?
        if let nav = r["navigationEndpoint"] as? [String: Any],
           let browse = nav["browseEndpoint"] as? [String: Any],
           let bid = browse["browseId"] as? String,
           (bid.hasPrefix("MPRE") || bid.hasPrefix("OLAK")) {
            browseId = bid
        }
        // Also check overlay for browse endpoint
        if browseId == nil,
           let overlay = r["overlay"] as? [String: Any],
           let overlayRenderer = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = overlayRenderer["content"] as? [String: Any],
           let playBtn = content["musicPlayButtonRenderer"] as? [String: Any],
           let nav = playBtn["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchPlaylistEndpoint"] as? [String: Any],
           let pid = watch["playlistId"] as? String {
            browseId = pid
        }
        guard let bid = browseId else { return nil }

        guard let columns = r["flexColumns"] as? [[String: Any]] else { return nil }
        let col0 = columns[safe: 0]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let titleRuns = (col0?["text"] as? [String: Any])?["runs"] as? [[String: Any]]
        guard let title = titleRuns?.first?["text"] as? String else { return nil }

        let col1 = columns[safe: 1]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
        let subtitleRuns = (col1?["text"] as? [String: Any])?["runs"] as? [[String: Any]]
        let subtitle = subtitleRuns?.compactMap { $0["text"] as? String }.joined()

        let thumbRenderer = (r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbnailURL = (thumbObj?["thumbnails"] as? [[String: Any]])?.last?["url"] as? String

        let pid = bid.hasPrefix("VL") ? String(bid.dropFirst(2)) : bid
        return Playlist(id: pid, title: title, subtitle: subtitle, thumbnailURL: thumbnailURL, tracks: [])
    }

    private func parsePlaylistsFromBrowse(_ data: Data) throws -> [Playlist] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }

        // Navigate: contents → singleColumnBrowseResultsRenderer → tabs[0] → tabRenderer
        // → content → sectionListRenderer → contents[] → gridRenderer → items[]
        // → musicTwoRowItemRenderer
        var playlists: [Playlist] = []

        func traverse(_ obj: Any, depth: Int = 0) {
            guard depth < 20 else { return }
            if let dict = obj as? [String: Any] {
                if let renderer = dict["musicTwoRowItemRenderer"] as? [String: Any] {
                    if let p = parsePlaylistRenderer(renderer) { playlists.append(p) }
                }
                for v in dict.values { traverse(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { traverse(item, depth: depth + 1) }
            }
        }
        traverse(json)

        // Deduplicate by id
        var seen = Set<String>()
        return playlists.filter { seen.insert($0.id).inserted }
    }

    private func parsePlaylistRenderer(_ r: [String: Any]) -> Playlist? {
        guard let titleObj = r["title"] as? [String: Any],
              let runs = titleObj["runs"] as? [[String: Any]],
              let title = runs.first?["text"] as? String else { return nil }

        guard let nav = r["navigationEndpoint"] as? [String: Any],
              let browse = nav["browseEndpoint"] as? [String: Any],
              let browseId = browse["browseId"] as? String else { return nil }

        let subtitleObj = r["subtitle"] as? [String: Any]
        let subtitleRuns = subtitleObj?["runs"] as? [[String: Any]]
        let subtitle = subtitleRuns?.compactMap { $0["text"] as? String }.joined()

        let thumbRenderer = (r["thumbnailRenderer"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbnails = thumbObj?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String

        let playlistId = browseId.hasPrefix("VL") ? String(browseId.dropFirst(2)) : browseId
        return Playlist(id: playlistId, title: title, subtitle: subtitle, thumbnailURL: thumbnailURL, tracks: [])
    }

    private func parseTracksFromPlaylist(_ data: Data) throws -> [Track] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YTMError.parseError("invalid JSON root")
        }

        let headerArtist = extractHeaderArtist(from: json)

        var tracks: [Track] = []
        var seenVideoIds = Set<String>()

        func traverse(_ obj: Any, depth: Int = 0) {
            guard depth < 25 else { return }
            if let dict = obj as? [String: Any] {
                // Music tracks
                if let renderer = dict["musicResponsiveListItemRenderer"] as? [String: Any] {
                    if let t = parseTrackRenderer(renderer, fallbackArtist: headerArtist),
                       seenVideoIds.insert(t.videoId).inserted {
                        tracks.append(t)
                    }
                }
                // Podcast episodes (different renderer type)
                if let renderer = dict["musicMultiRowListItemRenderer"] as? [String: Any] {
                    if let t = parsePodcastEpisodeRenderer(renderer, fallbackShow: headerArtist),
                       seenVideoIds.insert(t.videoId).inserted {
                        tracks.append(t)
                    }
                }
                for v in dict.values { traverse(v, depth: depth + 1) }
            } else if let arr = obj as? [Any] {
                for item in arr { traverse(item, depth: depth + 1) }
            }
        }
        traverse(json)

        return tracks
    }

    /// Parse a podcast episode from musicMultiRowListItemRenderer.
    /// Episodes have videoIds and play via the same watch endpoint as music, so
    /// download/playback work identically once the videoId is extracted.
    private func parsePodcastEpisodeRenderer(_ r: [String: Any], fallbackShow: String?) -> Track? {
        // Title
        let titleObj = r["title"] as? [String: Any]
        let titleRuns = titleObj?["runs"] as? [[String: Any]]
        let title = titleRuns?.compactMap { $0["text"] as? String }.joined() ?? ""
        guard !title.isEmpty else { return nil }

        // Show name from subtitle (e.g. "Show Name • Mar 15")
        let subtitleObj = r["subtitle"] as? [String: Any]
        let subtitleRuns = subtitleObj?["runs"] as? [[String: Any]] ?? []
        var show: String?
        for run in subtitleRuns {
            guard let text = run["text"] as? String,
                  text != " • " && text != ", " else { continue }
            if let nav = run["navigationEndpoint"] as? [String: Any],
               let browse = nav["browseEndpoint"] as? [String: Any],
               let id = browse["browseId"] as? String,
               id.hasPrefix("UC") || id.hasPrefix("MPSP") {
                show = text
                break
            }
        }
        if show == nil {
            // Fallback: first non-separator text in subtitle
            show = subtitleRuns
                .compactMap { $0["text"] as? String }
                .first { !$0.contains("•") && !$0.contains(",") && !$0.isEmpty }
        }
        let artist = show ?? fallbackShow ?? "Podcast"

        // videoId — try playButton, fallback to onTap
        var videoId: String?
        if let playButton = r["playButton"] as? [String: Any],
           let renderer = playButton["musicPlayButtonRenderer"] as? [String: Any],
           let nav = renderer["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any] {
            videoId = watch["videoId"] as? String
        }
        if videoId == nil,
           let onTap = r["onTap"] as? [String: Any],
           let watch = onTap["watchEndpoint"] as? [String: Any] {
            videoId = watch["videoId"] as? String
        }
        guard let vid = videoId else { return nil }

        // Duration — appears in description or footer
        var durationSeconds = 0
        if let secondTitle = r["secondTitle"] as? [String: Any],
           let runs = secondTitle["runs"] as? [[String: Any]] {
            for run in runs {
                if let text = run["text"] as? String {
                    let parsed = parseDuration(text)
                    if parsed > 0 { durationSeconds = parsed; break }
                }
            }
        }

        // Thumbnail
        let thumbRenderer = (r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbs = thumbObj?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbs?.last?["url"] as? String

        return Track(
            id: vid, videoId: vid, title: title, artist: artist,
            album: show, durationSeconds: durationSeconds, thumbnailURL: thumbnailURL
        )
    }

    private func extractHeaderArtist(from json: [String: Any]) -> String? {
        func findHeader(_ obj: Any, depth: Int = 0) -> [String: Any]? {
            guard depth < 15 else { return nil }
            if let dict = obj as? [String: Any] {
                if let header = dict["musicImmersiveHeaderRenderer"] as? [String: Any] { return header }
                if let header = dict["musicDetailHeaderRenderer"] as? [String: Any] { return header }
                if let header = dict["musicResponsiveHeaderRenderer"] as? [String: Any] { return header }
                for v in dict.values {
                    if let found = findHeader(v, depth: depth + 1) { return found }
                }
            } else if let arr = obj as? [Any] {
                for item in arr {
                    if let found = findHeader(item, depth: depth + 1) { return found }
                }
            }
            return nil
        }
        guard let header = findHeader(json) else { return nil }

        for key in ["subtitle", "straplineTextOne", "description"] {
            if let textObj = header[key] as? [String: Any],
               let runs = textObj["runs"] as? [[String: Any]] {
                let artistRuns = runs.filter { run in
                    if let nav = run["navigationEndpoint"] as? [String: Any],
                       let browse = nav["browseEndpoint"] as? [String: Any],
                       let id = browse["browseId"] as? String,
                       id.hasPrefix("UC") { return true }
                    return false
                }
                if !artistRuns.isEmpty {
                    return artistRuns.compactMap { $0["text"] as? String }.joined(separator: ", ")
                }
                let allText = runs.compactMap { $0["text"] as? String }
                    .filter { $0 != " • " && $0 != " & " && $0 != ", " }
                if let first = allText.first, !first.isEmpty {
                    return first
                }
            }
        }
        return nil
    }

    /// Bounded DFS for the first watchEndpoint.videoId anywhere in a renderer.
    private func firstWatchVideoId(in obj: Any, depth: Int = 0) -> String? {
        guard depth < 8 else { return nil }
        if let dict = obj as? [String: Any] {
            if let watch = dict["watchEndpoint"] as? [String: Any],
               let vid = watch["videoId"] as? String, !vid.isEmpty {
                return vid
            }
            for v in dict.values {
                if let found = firstWatchVideoId(in: v, depth: depth + 1) { return found }
            }
        } else if let arr = obj as? [Any] {
            for item in arr {
                if let found = firstWatchVideoId(in: item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    private func parseTrackRenderer(_ r: [String: Any], fallbackArtist: String? = nil) -> Track? {
        guard let columns = r["flexColumns"] as? [[String: Any]] else { return nil }

        func text(column: Int) -> String? {
            let col = columns[safe: column]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any]
            let textObj = col?["text"] as? [String: Any]
            let runs = textObj?["runs"] as? [[String: Any]]
            guard let runs, !runs.isEmpty else { return nil }
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }

        guard let title = text(column: 0) else { return nil }

        var artist: String?
        var artistId: String?
        var album: String?
        var albumId: String?

        if let col1Renderer = columns[safe: 1]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textObj = col1Renderer["text"] as? [String: Any],
           let runs = textObj["runs"] as? [[String: Any]], !runs.isEmpty {
            var artistNames: [String] = []
            for run in runs {
                guard let text = run["text"] as? String else { continue }
                if let nav = run["navigationEndpoint"] as? [String: Any],
                   let browse = nav["browseEndpoint"] as? [String: Any],
                   let id = browse["browseId"] as? String {
                    if id.hasPrefix("UC") {
                        artistNames.append(text)
                        if artistId == nil { artistId = id }
                    } else if id.hasPrefix("MPRE") || id.hasPrefix("OLAK") || id.hasPrefix("RDCL") {
                        if album == nil { album = text }
                        if albumId == nil { albumId = id }
                    }
                }
            }
            if !artistNames.isEmpty {
                artist = artistNames.joined(separator: ", ")
            } else {
                let typeKeywords: Set<String> = ["Song", "Video", "Album", "EP", "Single", "Playlist"]
                let textRuns = runs.compactMap { $0["text"] as? String }
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0 != " • " && $0 != " & " && $0 != ", " }
                    .filter { !typeKeywords.contains($0) }
                let joined = textRuns.joined(separator: ", ")
                if !joined.isEmpty { artist = joined }
            }
        }

        if let col2Renderer = columns[safe: 2]?["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
           let textObj = col2Renderer["text"] as? [String: Any],
           let runs = textObj["runs"] as? [[String: Any]], !runs.isEmpty {
            if album == nil { album = runs.compactMap { $0["text"] as? String }.joined() }
            if albumId == nil, let firstRun = runs.first,
               let nav = firstRun["navigationEndpoint"] as? [String: Any],
               let browse = nav["browseEndpoint"] as? [String: Any],
               let id = browse["browseId"] as? String {
                albumId = id
            }
        }

        // Fallback: check longBylineText, shortBylineText, subtitle
        if artist == nil || artist?.isEmpty == true {
            for key in ["longBylineText", "shortBylineText", "subtitle"] {
                if let byline = r[key] as? [String: Any],
                   let runs = byline["runs"] as? [[String: Any]], !runs.isEmpty {
                    let joined = runs.compactMap { $0["text"] as? String }.joined()
                    if !joined.isEmpty { artist = joined; break }
                }
            }
        }

        // videoId can live in several places depending on the endpoint (search vs
        // playlist vs home). Try them all — search results in particular often use
        // playlistItemData or a top-level navigationEndpoint rather than the overlay.
        var videoId: String?
        if let overlay = r["overlay"] as? [String: Any],
           let playButton = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = playButton["content"] as? [String: Any],
           let playBtn = content["musicPlayButtonRenderer"] as? [String: Any],
           let nav = playBtn["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any] {
            videoId = watch["videoId"] as? String
        }
        if videoId == nil, let pid = (r["playlistItemData"] as? [String: Any])?["videoId"] as? String {
            videoId = pid
        }
        if videoId == nil,
           let nav = r["navigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any] {
            videoId = watch["videoId"] as? String
        }
        // Last resort — first flexColumn run with a watchEndpoint videoId
        if videoId == nil {
            videoId = firstWatchVideoId(in: r)
        }

        guard let vid = videoId else { return nil }

        var durationSeconds = 0
        if let fixed = r["fixedColumns"] as? [[String: Any]] {
            let fixedCol = fixed.first?["musicResponsiveListItemFixedColumnRenderer"] as? [String: Any]
            let fixedText = fixedCol?["text"] as? [String: Any]
            let fixedRuns = fixedText?["runs"] as? [[String: Any]]
            if let durText = fixedRuns?.first?["text"] as? String {
                durationSeconds = parseDuration(durText)
            }
        }
        if durationSeconds == 0, let overlay = r["overlay"] as? [String: Any],
           let playButton = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
           let content = playButton["content"] as? [String: Any],
           let playBtn = content["musicPlayButtonRenderer"] as? [String: Any],
           let nav = playBtn["playNavigationEndpoint"] as? [String: Any],
           let watch = nav["watchEndpoint"] as? [String: Any] {
            if let lenSec = watch["lengthSeconds"] as? Int {
                durationSeconds = lenSec
            } else if let lenStr = watch["lengthSeconds"] as? String, let len = Int(lenStr) {
                durationSeconds = len
            }
        }
        if durationSeconds == 0 {
            let durationPattern = try? NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}$")
            for col in columns {
                if let renderer = col["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                   let textObj = renderer["text"] as? [String: Any],
                   let runs = textObj["runs"] as? [[String: Any]] {
                    for run in runs {
                        if let text = run["text"] as? String,
                           let regex = durationPattern,
                           regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                            durationSeconds = parseDuration(text)
                            break
                        }
                    }
                }
                if durationSeconds > 0 { break }
            }
        }

        let thumbRenderer = (r["thumbnail"] as? [String: Any])?["musicThumbnailRenderer"] as? [String: Any]
        let thumbObj = thumbRenderer?["thumbnail"] as? [String: Any]
        let thumbnails = thumbObj?["thumbnails"] as? [[String: Any]]
        let thumbnailURL = thumbnails?.last?["url"] as? String

        return Track(
            id: vid,
            videoId: vid,
            title: title,
            artist: artist ?? fallbackArtist ?? "Unknown",
            album: album,
            durationSeconds: durationSeconds,
            thumbnailURL: thumbnailURL,
            artistId: artistId,
            albumId: albumId
        )
    }

    private func parseDuration(_ s: String) -> Int {
        let parts = s.split(separator: ":").map { Int($0) ?? 0 }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return 0
    }
}

// MARK: - Errors

enum YTMError: LocalizedError {
    case httpError(Int)
    case parseError(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .notAuthenticated: return "Not logged in"
        }
    }
}

// MARK: - Cookie archiving (HTTPCookie isn't Codable)

private struct CookieArchive: Codable {
    let properties: [String: String]

    init(cookie: HTTPCookie) {
        var p: [String: String] = [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path
        ]
        if cookie.isSecure { p["secure"] = "TRUE" }
        properties = p
    }

    var cookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [:]
        if let n = properties["name"] { props[.name] = n }
        if let v = properties["value"] { props[.value] = v }
        if let d = properties["domain"] { props[.domain] = d }
        if let p = properties["path"] { props[.path] = p }
        return HTTPCookie(properties: props)
    }
}

// MARK: - Safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
