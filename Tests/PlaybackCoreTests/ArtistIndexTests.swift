import XCTest
@testable import PlaybackCore

final class ArtistIndexTests: XCTestCase {

    private func track(_ id: String, _ artist: String, artistId: String? = nil) -> Track {
        Track(id: id, videoId: id, title: "Song \(id)", artist: artist, durationSeconds: 200, artistId: artistId)
    }

    func testGroupsAcrossPlaylistsAndListsCollabsUnderEachArtist() {
        let groups = ArtistIndex.group([
            track("a", "Van Zee", artistId: "UCvz"),
            track("b", "Drake, Don Toliver", artistId: "UCdrake"),
            track("c", "Don Toliver", artistId: "UCdon"),
            track("a", "Van Zee"),  // same song from a second playlist
        ])
        XCTAssertEqual(groups.map(\.name), ["Don Toliver", "Drake", "Van Zee"])
        XCTAssertEqual(groups[0].tracks.map(\.videoId), ["b", "c"])
        XCTAssertEqual(groups[2].tracks.map(\.videoId), ["a"], "duplicates across playlists count once")
    }

    func testArtistIdComesOnlyFromTheFirstArtistOnATrack() {
        let groups = ArtistIndex.group([
            track("b", "Drake, Don Toliver", artistId: "UCdrake"),
            track("c", "Don Toliver", artistId: "UCdon"),
        ])
        XCTAssertEqual(groups.first { $0.name == "Drake" }?.artistId, "UCdrake")
        XCTAssertEqual(groups.first { $0.name == "Don Toliver" }?.artistId, "UCdon",
                       "the collab's id belongs to Drake, not Don Toliver")
    }

    func testCaseInsensitiveMergeAndPlaceholdersSkipped() {
        let groups = ArtistIndex.group([
            track("a", "Central Cee"),
            track("b", "central cee"),
            track("c", "Unknown"),
            track("d", ""),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].name, "Central Cee")
        XCTAssertEqual(groups[0].tracks.count, 2)
    }

    // MARK: - Sorting and search

    private var library: [ArtistGroup] {
        ArtistIndex.group([
            track("a1", "Alpha"), track("a2", "Alpha"), track("a3", "Alpha"),
            track("b1", "Bravo"),
            track("c1", "Charlie"), track("c2", "Charlie"),
            track("z1", "Zulu"),
        ])
    }

    func testSortByDownloadedCountsOnlyDownloadedSongs() {
        let downloaded: Set = ["b1", "c1", "c2", "a1"]
        let names = ArtistIndex.sorted(library, by: .downloaded, recent: [],
                                       isDownloaded: { downloaded.contains($0) }).map(\.name)
        XCTAssertEqual(names, ["Charlie", "Alpha", "Bravo", "Zulu"],
                       "Alpha has 3 songs but only 1 downloaded; ties break by name")
    }

    func testSortByRecentUsesEachArtistsLatestPlayThenName() {
        // most recent first: Zulu, then a Charlie song, then an Alpha song
        let names = ArtistIndex.sorted(library, by: .recent, recent: ["z1", "c2", "a3", "c1"],
                                       isDownloaded: { _ in true }).map(\.name)
        XCTAssertEqual(names, ["Zulu", "Charlie", "Alpha", "Bravo"], "never-played artists go last")
    }

    func testSortByName() {
        let names = ArtistIndex.sorted(library, by: .name, recent: ["z1"], isDownloaded: { _ in false }).map(\.name)
        XCTAssertEqual(names, ["Alpha", "Bravo", "Charlie", "Zulu"])
    }

    func testSearchIsCaseAndAccentInsensitive() {
        let groups = ArtistIndex.group([track("a", "Beyoncé"), track("b", "Bad Bunny"), track("c", "Rosalía")])
        XCTAssertEqual(ArtistIndex.filter(groups, query: "beyonce").map(\.name), ["Beyoncé"])
        XCTAssertEqual(ArtistIndex.filter(groups, query: "  ROSALIA ").map(\.name), ["Rosalía"])
        XCTAssertEqual(ArtistIndex.filter(groups, query: "").count, 3)
    }

    // MARK: - Placeholder artists ("Album" bug)

    func testPlaceholderArtistsAreRecognised() {
        for bad in ["Album", "album", " EP ", "Single", "Unknown", "", "2006"] {
            XCTAssertTrue(ArtistIndex.isPlaceholderArtist(bad), bad)
        }
        for good in ["Arctic Monkeys", "Album Leaf", "The 1975", "Blink-182"] {
            XCTAssertFalse(ArtistIndex.isPlaceholderArtist(good), good)
        }
    }

    func testAlbumIsNeverListedAsAnArtist() {
        let groups = ArtistIndex.group([track("a", "Album"), track("b", "Arctic Monkeys")])
        XCTAssertEqual(groups.map(\.name), ["Arctic Monkeys"])
    }

    func testWatchMergeUpgradesPlaceholderArtistsOnly() {
        let local = [track("a", "Album"), track("b", "Local Name"), track("c", "Album")]
        let incoming = [track("a", "Arctic Monkeys", artistId: "UC1"), track("b", "Phone Name"),
                        track("c", "Album"), track("d", "New Song Artist")]
        let merged = LibraryReconciler.mergedTracks(local: local, incoming: incoming)
        XCTAssertEqual(merged.map(\.videoId), ["a", "b", "c", "d"], "local order kept, new appended")
        XCTAssertEqual(merged.map(\.artist), ["Arctic Monkeys", "Local Name", "Album", "New Song Artist"],
                       "only placeholders are replaced, and only by a real name")
        XCTAssertEqual(merged[0].artistId, "UC1")
    }
}
