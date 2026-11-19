import XCTest
@testable import LyricsSearchKit

final class LyricsFuzzySearchTests: XCTestCase {

    func testNormalizePunctuationCaseDiacriticsContractions() {
        XCTAssertEqual(LyricsFuzzySearch.normalize("Don't Stop Believin'"), "dont stop believin")
        XCTAssertEqual(LyricsFuzzySearch.normalize("café au lait"), "cafe au lait")
        XCTAssertEqual(LyricsFuzzySearch.normalize("HELLO, WORLD!!!"), "hello world")
        XCTAssertEqual(LyricsFuzzySearch.normalize("it’s a beautiful day"), "its a beautiful day")
    }

    func testMisspelledLine() {
        let doc = LyricsFuzzySearch.document(
            songId: "1",
            title: "Never Gonna Give You Up",
            artist: "Rick Astley",
            album: "Whenever",
            plainContent: "Never gonna give you up\nNever gonna let you down"
        )
        let hits = LyricsFuzzySearch.search(documents: [doc], query: "never gonna giv you up", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].matchedLine.lowercased().contains("give you up"))
        XCTAssertGreaterThan(hits[0].score, 0)
        XCTAssertTrue(hits[0].accessibilityLabel.hasPrefix("Lyric match:"))
    }

    func testReorderedLinePrefersInOrder() {
        let doc = LyricsFuzzySearch.document(
            songId: "1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            plainContent: "we're no strangers to love\nyou know the rules and so do I"
        )
        let reordered = LyricsFuzzySearch.search(documents: [doc], query: "strangers love no", limit: 5)
        let ordered = LyricsFuzzySearch.search(documents: [doc], query: "no strangers to love", limit: 5)
        XCTAssertEqual(reordered.count, 1)
        XCTAssertEqual(ordered.count, 1)
        XCTAssertGreaterThan(ordered[0].score, reordered[0].score)
    }

    func testPunctuationHeavyLine() {
        let doc = LyricsFuzzySearch.document(
            songId: "1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            plainContent: #"She said, "Don't you know?" — it's over now!!!"#
        )
        let hits = LyricsFuzzySearch.search(documents: [doc], query: "dont you know its over", limit: 5)
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(hits[0].matchRanges.isEmpty)
    }

    func testNonMatch() {
        let doc = LyricsFuzzySearch.document(
            songId: "1",
            title: "Song",
            artist: "Artist",
            album: "Album",
            plainContent: "Never gonna give you up\nNever gonna let you down"
        )
        let hits = LyricsFuzzySearch.search(documents: [doc], query: "purple elephant sandwich", limit: 5)
        XCTAssertTrue(hits.isEmpty)
    }

    func testTokenTypoTolerance() {
        XCTAssertEqual(LyricsFuzzySearch.tokenSimilarity("give", "give"), 1)
        XCTAssertGreaterThan(LyricsFuzzySearch.tokenSimilarity("giv", "give"), 0.5)
        XCTAssertGreaterThan(LyricsFuzzySearch.tokenSimilarity("believin", "believing"), 0.5)
        XCTAssertEqual(LyricsFuzzySearch.tokenSimilarity("xyz", "give"), 0)
    }
}
