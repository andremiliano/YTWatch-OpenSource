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
}
