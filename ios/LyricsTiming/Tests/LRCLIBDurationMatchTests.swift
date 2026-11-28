import XCTest
@testable import LRCParser

/// Calls the real `LRCLIBClient.pickBest` (synced into this package by
/// `scripts/test-lyrics-timing.sh`).
final class LRCLIBDurationMatchTests: XCTestCase {

    func testPrefers311sAlbumCutOver214sRadioEdit() {
        let trackSec = 311 // 310.72s FLAC rounded
        let radio = LRCLIBClient.Result(
            id: 214000,
            trackName: "Bitch, Don't Kill My Vibe",
            artistName: "Kendrick Lamar",
            duration: 214,
            hasWordSync: true,
            syncedLyrics: "[00:01.00] <00:01.00>radio <00:01.40>edit\n"
        )
        let album = LRCLIBClient.Result(
            id: 565635,
            trackName: "Bitch, Don't Kill My Vibe",
            artistName: "Kendrick Lamar",
            albumName: "good kid, m.A.A.d city",
            duration: 311,
            hasWordSync: true,
            syncedLyrics: "[00:01.00] <00:01.00>album <00:01.40>cut\n"
        )
        let best = LRCLIBClient.pickBest(
            from: [radio, album],
            album: "good kid, m.A.A.d city",
            duration: trackSec)
        XCTAssertEqual(best?.id, 565635)
    }

    func testRejectsSyncedWhenOnlyMismatchedCutExists() {
        let radio = LRCLIBClient.Result(
            id: 214000,
            trackName: "Bitch, Don't Kill My Vibe",
            artistName: "Kendrick Lamar",
            duration: 214,
            hasWordSync: true,
            syncedLyrics: "[00:01.00] <00:01.00>radio\n"
        )
        XCTAssertNil(LRCLIBClient.pickBest(from: [radio], album: nil, duration: 311))
    }

    func testPrefersWordSyncAtMatchingDurationAdele() {
        // GET returns line-only 15850 @285s; search has word-sync 7137504 @285s.
        let lineOnly = LRCLIBClient.Result(
            id: 15850,
            trackName: "Someone Like You",
            artistName: "Adele",
            albumName: "21",
            duration: 285,
            hasWordSync: false,
            syncedLyrics: "[00:14.08] I heard that you're settled down\n",
            lyricsfile: """
                version: '1.0'
                lines:
                - text: I heard that you're settled down
                  start_ms: 14080
                """
        )
        let word = LRCLIBClient.Result(
            id: 7137504,
            trackName: "Someone Like You",
            artistName: "Adele",
            albumName: "21",
            duration: 285,
            hasWordSync: true,
            syncedLyrics: "[00:14.32] I heard that you're settled down\n",
            lyricsfile: """
                version: '1.0'
                lines:
                - text: I heard that you're settled down
                  start_ms: 14320
                  words:
                  - text: 'I '
                    start_ms: 14320
                  - text: heard
                    start_ms: 15030
                """
        )
        let best = LRCLIBClient.pickBest(from: [lineOnly, word], album: "21", duration: 285)
        XCTAssertEqual(best?.id, 7137504)
    }

    func testNeverBorrowsWrongDurationWordSync() {
        let lineMatched = LRCLIBClient.Result(
            id: 314000,
            trackName: "Swimming Pools",
            artistName: "Kendrick Lamar",
            duration: 314,
            syncedLyrics: "[00:01.00] extended line\n"
        )
        let wordShort = LRCLIBClient.Result(
            id: 248000,
            trackName: "Swimming Pools",
            artistName: "Kendrick Lamar",
            duration: 248,
            hasWordSync: true,
            syncedLyrics: "[00:01.00] <00:01.00>short <00:01.40>edit\n"
        )
        let best = LRCLIBClient.pickBest(from: [wordShort, lineMatched], album: nil, duration: 314)
        XCTAssertEqual(best?.id, 314000)
        if let synced = best.flatMap({ LRCLIBClient.effectiveSyncedLyrics($0) }) {
            XCTAssertFalse(LRCLIBClient.hasWordSync(synced))
        }
    }

    func testUnstampedSyncedProvenanceInvalidated() {
        let raw = "[00:01.00] <00:01.00>hello\n[05:05.00] <05:05.00>world\n"
        XCTAssertFalse(
            LRCLIBClient.provenanceDurationMatchesTrack(raw, trackDurationSec: 311)
        )
    }

    func testStampedProvenanceWithinTolerance() {
        let raw = """
            [drome-lrclib-id:565635]
            [drome-lrclib-duration:311.000]
            [00:01.000] <00:01.000>hello
            """
        XCTAssertTrue(
            LRCLIBClient.provenanceDurationMatchesTrack(raw, trackDurationSec: 311)
        )
        XCTAssertFalse(
            LRCLIBClient.provenanceDurationMatchesTrack(raw, trackDurationSec: 214)
        )
        XCTAssertEqual(LRCLIBClient.parseProvenanceId(raw), 565635)
    }
}
