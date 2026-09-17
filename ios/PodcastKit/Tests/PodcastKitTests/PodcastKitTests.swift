import XCTest
@testable import PodcastKit

final class RSSPodcastParserTests: XCTestCase {

    func testParsesShowMetadata() throws {
        let xml = try fixture("sample_feed.xml")
        let (show, episodes) = try RSSPodcastParser.parseFeed(
            xml: xml,
            feedURL: "https://example.com/feed.xml")

        XCTAssertEqual(show.title, "Drome Test Podcast")
        XCTAssertEqual(show.author, "Drome Labs")
        XCTAssertEqual(show.category, "Technology")
        XCTAssertEqual(show.imageURL?.absoluteString, "https://example.com/art.jpg")
        XCTAssertEqual(show.feedURL, "https://example.com/feed.xml")
        XCTAssertFalse(show.explicit)
        XCTAssertEqual(episodes.count, 2) // broken + file:/// skipped
    }

    func testParsesEpisodeDurationHHMMSS() throws {
        let xml = try fixture("sample_feed.xml")
        let (_, episodes) = try RSSPodcastParser.parseFeed(
            xml: xml,
            feedURL: "https://example.com/feed.xml")

        let first = try XCTUnwrap(episodes.first)
        XCTAssertEqual(first.title, "Episode One: Beginnings")
        XCTAssertEqual(first.id, "ep-001")
        XCTAssertEqual(first.duration, 1 * 3600 + 15 * 60 + 30)
        XCTAssertEqual(first.episodeNumber, 1)
        XCTAssertEqual(first.seasonNumber, 1)
        XCTAssertEqual(first.audioURL.absoluteString, "https://example.com/audio/ep001.mp3")
        XCTAssertTrue(first.description?.contains("First episode with") == true)
        XCTAssertTrue(first.description?.contains("HTML") == true)
    }

    func testParsesEpisodeDurationSeconds() throws {
        let xml = try fixture("sample_feed.xml")
        let (_, episodes) = try RSSPodcastParser.parseFeed(
            xml: xml,
            feedURL: "https://example.com/feed.xml")

        let second = try XCTUnwrap(episodes.dropFirst().first)
        XCTAssertEqual(second.duration, 185)
        XCTAssertEqual(second.durationText, "3:05")
    }

    func testSkipsInvalidEnclosures() throws {
        let xml = try fixture("sample_feed.xml")
        let (_, episodes) = try RSSPodcastParser.parseFeed(
            xml: xml,
            feedURL: "https://example.com/feed.xml")

        XCTAssertFalse(episodes.contains { $0.id == "no-audio" })
        XCTAssertFalse(episodes.contains { $0.id == "bad-file" })
        XCTAssertFalse(episodes.contains { $0.audioURL.scheme == "file" })
    }

    func testDurationParsingHelpers() {
        XCTAssertEqual(RSSPodcastParser.parseDuration("90"), 90)
        XCTAssertEqual(RSSPodcastParser.parseDuration("1:30"), 90)
        XCTAssertEqual(RSSPodcastParser.parseDuration("1:02:03"), 3723)
        XCTAssertNil(RSSPodcastParser.parseDuration(""))
        XCTAssertNil(RSSPodcastParser.parseDuration("not-a-duration"))
    }

    func testIsHTTPURLRejectsFileAndEmpty() {
        XCTAssertTrue(RSSPodcastParser.isHTTPURL("https://example.com/feed.xml"))
        XCTAssertTrue(RSSPodcastParser.isHTTPURL("http://example.com/a.mp3"))
        XCTAssertFalse(RSSPodcastParser.isHTTPURL(""))
        XCTAssertFalse(RSSPodcastParser.isHTTPURL("file:///"))
        XCTAssertFalse(RSSPodcastParser.isHTTPURL("file:///dev/null"))
        XCTAssertFalse(RSSPodcastParser.isHTTPURL("/local/path"))
        XCTAssertFalse(RSSPodcastParser.isHTTPURL("not a url"))
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "sample_feed", withExtension: "xml")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }
}

final class PodcastStoreTests: XCTestCase {

    private var store: PodcastStore!
    private var dbPath: String!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PodcastKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbPath = dir.appendingPathComponent("podcasts.sqlite").path
        store = try PodcastStore(dbPath: dbPath)
    }

    override func tearDownWithError() throws {
        store = nil
        if let dbPath {
            try? FileManager.default.removeItem(atPath: (dbPath as NSString).deletingLastPathComponent)
        }
    }

    func testSubscribeAndListShows() throws {
        let show = PodcastShow(
            title: "Test Show",
            author: "Host",
            imageURL: URL(string: "https://example.com/art.jpg"),
            feedURL: "https://example.com/feed.xml")

        try store.subscribe(show)
        XCTAssertTrue(try store.isSubscribed(feedURL: show.feedURL))

        let shows = try store.subscribedShows()
        XCTAssertEqual(shows.count, 1)
        XCTAssertEqual(shows.first?.title, "Test Show")
        XCTAssertEqual(shows.first?.imageURL?.absoluteString, "https://example.com/art.jpg")
    }

    func testUpsertEpisodesAndPlaybackPosition() throws {
        let feed = "https://example.com/feed.xml"
        try store.subscribe(PodcastShow(title: "Show", feedURL: feed))

        let episode = PodcastEpisode(
            id: "ep-1",
            showID: feed,
            title: "Ep 1",
            description: nil,
            pubDate: Date(),
            duration: 600,
            audioURL: URL(string: "https://example.com/ep1.mp3")!,
            imageURL: URL(string: "https://example.com/ep1.jpg"),
            episodeNumber: 1,
            seasonNumber: 1,
            episodeType: "full",
            explicit: false,
            fileSize: 1000,
            mimeType: "audio/mpeg")

        try store.upsertEpisodes([episode])
        var loaded = try store.episodes(for: feed)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].playbackPosition, 0)

        try store.savePlaybackPosition(episodeID: "ep-1", showFeedURL: feed, position: 120, completed: false)
        loaded = try store.episodes(for: feed)
        XCTAssertEqual(loaded[0].playbackPosition, 120)

        let inProgress = try store.inProgressEpisodes()
        XCTAssertEqual(inProgress.count, 1)
        XCTAssertEqual(inProgress[0].position, 120)
    }

    func testUnsubscribeRemovesShow() throws {
        let feed = "https://example.com/feed.xml"
        try store.subscribe(PodcastShow(title: "Show", feedURL: feed))
        try store.unsubscribe(feedURL: feed)
        XCTAssertFalse(try store.isSubscribed(feedURL: feed))
        XCTAssertTrue(try store.subscribedShows().isEmpty)
    }
}

final class LiveFeedSmokeTests: XCTestCase {

    /// Fetches a known public feed. Skipped automatically when offline.
    func testFetchNPRUpFirst() async throws {
        let url = URL(string: "https://feeds.npr.org/510318/podcast.xml")!
        do {
            let (show, episodes) = try await RSSPodcastParser.fetchFeed(url: url)
            XCTAssertFalse(show.title.isEmpty)
            XCTAssertFalse(episodes.isEmpty)
            XCTAssertTrue(episodes.allSatisfy { $0.audioURL.scheme == "https" || $0.audioURL.scheme == "http" })
            XCTAssertNotNil(episodes.first?.audioURL.host)
            print("Live feed OK: \(show.title) — \(episodes.count) episodes, first=\(episodes[0].title)")
        } catch {
            throw XCTSkip("Network unavailable or feed unreachable: \(error)")
        }
    }
}
