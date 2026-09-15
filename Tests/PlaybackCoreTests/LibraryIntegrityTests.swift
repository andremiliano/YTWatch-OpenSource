import XCTest
@testable import PlaybackCore

final class LibraryIntegrityTests: XCTestCase {

    private func track(_ id: String, title: String? = nil) -> Track {
        Track(id: id, videoId: id, title: title ?? "Song \(id)", artist: "Artist", durationSeconds: 200)
    }

    private func placeholder(_ id: String) -> Track {
        Track(id: id, videoId: id, title: id, artist: "Unknown", durationSeconds: 0)
    }

    // MARK: - Lossy decoding (a single bad record must never wipe the library)

    func testOneMalformedTrackDoesNotLoseThePlaylist() throws {
        let json = """
        [{"id":"PL1","title":"Album","tracks":[
            {"id":"a","videoId":"a","title":"Good","artist":"X","durationSeconds":100},
            {"id":"b","title":"No videoId — unrecoverable"},
            {"id":"c","videoId":"c","title":"Also good","artist":"X","durationSeconds":"not a number"}
        ]}]
        """.data(using: .utf8)!
        let playlists = try XCTUnwrap(Playlist.decodeLossy(from: json))
        XCTAssertEqual(playlists.count, 1)
        XCTAssertEqual(playlists[0].tracks.map(\.videoId), ["a", "c"])
        XCTAssertEqual(playlists[0].tracks[1].durationSeconds, 0, "bad duration degrades, not fails")
    }

    func testOneMalformedPlaylistDoesNotLoseTheOthers() throws {
        let json = """
        [{"id":"PL1","title":"Keep","tracks":[]},
         {"title":"Missing id"},
         {"id":"PL3","title":"Keep too","tracks":[{"videoId":"z"}]}]
        """.data(using: .utf8)!
        let playlists = try XCTUnwrap(Playlist.decodeLossy(from: json))
        XCTAssertEqual(playlists.map(\.id), ["PL1", "PL3"])
    }

    // Previously a strict decode: every field required, so a track saved by an older build
    // without e.g. `artist` failed the whole library -> every file orphaned as a raw id.
    func testTrackMissingOptionalFieldsDecodesWithDefaults() throws {
        let json = #"{"videoId":"abc"}"#.data(using: .utf8)!
        let t = try JSONDecoder().decode(Track.self, from: json)
        XCTAssertEqual(t.id, "abc")
        XCTAssertEqual(t.title, "abc")
        XCTAssertEqual(t.artist, "")
        XCTAssertEqual(t.durationSeconds, 0)
    }

    func testPlaylistRoundTripIsLossless() throws {
        let original = [Playlist(id: "PL", title: "T", subtitle: "S", thumbnailURL: "u",
                                 tracks: [Track(id: "a", videoId: "a", title: "日本語 ✓", artist: "A",
                                                album: "Al", durationSeconds: 5, thumbnailURL: "t",
                                                artistId: "ai", albumId: "bi")])]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(Playlist.decodeLossy(from: data), original)
    }

    func testTruncatedJSONReturnsNilSoCallerCanPreserveTheFile() {
        let data = #"[{"id":"PL1","title":"Alb"#.data(using: .utf8)!
        XCTAssertNil(Playlist.decodeLossy(from: data))
    }

    // MARK: - Unsorted reconciliation

    func testPlaceholderDuplicatesArePrunedFromUnsorted() throws {
        let playlists = [
            Playlist(id: "PL", title: "Album", thumbnailURL: nil, tracks: [track("a"), track("b")]),
            Playlist(id: LibraryReconciler.unsortedId, title: "Unsorted", thumbnailURL: nil,
                     tracks: [placeholder("a"), placeholder("x")]),
        ]
        let result = try XCTUnwrap(LibraryReconciler.pruneUnsorted(playlists))
        let unsorted = try XCTUnwrap(result.first { $0.id == LibraryReconciler.unsortedId })
        XCTAssertEqual(unsorted.tracks.map(\.videoId), ["x"], "only the truly orphaned track stays")
        XCTAssertEqual(result.first { $0.id == "PL" }?.tracks.count, 2, "real playlists untouched")
    }

    func testUnsortedIsRemovedWhenEmptied() throws {
        let playlists = [
            Playlist(id: "PL", title: "Album", thumbnailURL: nil, tracks: [track("a")]),
            Playlist(id: LibraryReconciler.unsortedId, title: "Unsorted", thumbnailURL: nil, tracks: [placeholder("a")]),
        ]
        let result = try XCTUnwrap(LibraryReconciler.pruneUnsorted(playlists))
        XCTAssertEqual(result.map(\.id), ["PL"])
    }

    func testPruneReportsNoChangeWhenNothingToDo() {
        let noUnsorted = [Playlist(id: "PL", title: "A", thumbnailURL: nil, tracks: [track("a")])]
        XCTAssertNil(LibraryReconciler.pruneUnsorted(noUnsorted))

        let disjoint = noUnsorted + [Playlist(id: LibraryReconciler.unsortedId, title: "Unsorted",
                                              thumbnailURL: nil, tracks: [placeholder("z")])]
        XCTAssertNil(LibraryReconciler.pruneUnsorted(disjoint))
    }

    func testPruneNeverDropsAudioThatHasNoOtherHome() throws {
        // Fuzz: whatever the overlap, every videoId present before is present after.
        var rng = SeededRNG(seed: 7)
        for _ in 0..<300 {
            let pool = (0..<30).map { "v\($0)" }
            let albumIds = pool.filter { _ in Bool.random(using: &rng) }
            let unsortedIds = pool.filter { _ in Bool.random(using: &rng) }
            let before = [
                Playlist(id: "PL", title: "A", thumbnailURL: nil, tracks: albumIds.map { track($0) }),
                Playlist(id: LibraryReconciler.unsortedId, title: "Unsorted", thumbnailURL: nil,
                         tracks: unsortedIds.map { placeholder($0) }),
            ]
            let after = LibraryReconciler.pruneUnsorted(before) ?? before
            let idsBefore = Set(before.flatMap { $0.tracks.map(\.videoId) })
            let idsAfter = Set(after.flatMap { $0.tracks.map(\.videoId) })
            XCTAssertEqual(idsBefore, idsAfter)
            // and no videoId appears in both Unsorted and a real playlist
            let unsortedAfter = Set(after.first { $0.id == LibraryReconciler.unsortedId }?.tracks.map(\.videoId) ?? [])
            XCTAssertTrue(unsortedAfter.isDisjoint(with: albumIds))
        }
    }

    func testPlaceholderIdsOnlyReportsRawIdTitles() {
        let playlists = [
            Playlist(id: "PL", title: "A", thumbnailURL: nil, tracks: [placeholder("inAlbum")]),
            Playlist(id: LibraryReconciler.unsortedId, title: "Unsorted", thumbnailURL: nil,
                     tracks: [placeholder("raw1"), track("titled"), placeholder("raw2")]),
        ]
        XCTAssertEqual(LibraryReconciler.placeholderIds(in: playlists), ["raw1", "raw2"])
    }
}
