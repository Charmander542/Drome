import Foundation
import Combine

/// Manages podcast subscriptions, feed refreshes, and episode discovery.
@MainActor
final class PodcastManager: ObservableObject {
    @Published var subscribedShows: [PodcastShow] = []
    @Published var isRefreshing = false
    @Published var refreshError: String?

    private let store: PodcastStore

    init(store: PodcastStore) {
        self.store = store
        loadSubscriptions()
    }

    // MARK: - Subscriptions

    func loadSubscriptions() {
        do {
            subscribedShows = try store.subscribedShows()
        } catch {
            print("[PodcastManager] Failed to load subscriptions: \(error)")
        }
    }

    func isSubscribed(feedURL: String) -> Bool {
        (try? store.isSubscribed(feedURL: feedURL)) ?? false
    }

    func subscribe(to feedURL: String) async throws {
        guard let url = Self.httpURL(from: feedURL) else {
            throw PodcastError.invalidFeed
        }
        let (show, episodes) = try await RSSPodcastParser.fetchFeed(url: url)

        var updatedShow = show
        updatedShow.episodeCount = episodes.count
        updatedShow.lastUpdated = Date()

        try store.subscribe(updatedShow)
        try store.upsertEpisodes(episodes)

        loadSubscriptions()
    }

    func subscribe(to show: PodcastShow) throws {
        guard RSSPodcastParser.isHTTPURL(show.feedURL) else {
            throw PodcastError.invalidFeed
        }
        try store.subscribe(show)
        loadSubscriptions()
    }

    func unsubscribe(feedURL: String) throws {
        try store.unsubscribe(feedURL: feedURL)
        loadSubscriptions()
    }

    // MARK: - Episodes

    func episodes(for feedURL: String) throws -> [PodcastEpisode] {
        try store.episodes(for: feedURL)
    }

    /// Refresh a single show's feed, adding any new episodes.
    func refreshFeed(feedURL: String) async {
        guard let url = Self.httpURL(from: feedURL) else { return }

        do {
            let (show, episodes) = try await RSSPodcastParser.fetchFeed(url: url)

            var updatedShow = show
            updatedShow.episodeCount = episodes.count
            updatedShow.lastUpdated = Date()

            try store.updateShow(updatedShow)
            try store.upsertEpisodes(episodes)
            loadSubscriptions()
        } catch {
            print("[PodcastManager] Failed to refresh feed \(feedURL): \(error)")
        }
    }

    /// Refresh all subscribed feeds.
    func refreshAll() async {
        isRefreshing = true
        refreshError = nil

        let shows = subscribedShows
        var errors: [String] = []

        for show in shows {
            guard let url = Self.httpURL(from: show.feedURL) else {
                errors.append("\(show.title): invalid feed URL")
                continue
            }
            do {
                let (updatedShow, episodes) = try await RSSPodcastParser.fetchFeed(url: url)

                var finalShow = updatedShow
                finalShow.episodeCount = episodes.count
                finalShow.lastUpdated = Date()

                try store.updateShow(finalShow)
                try store.upsertEpisodes(episodes)
            } catch {
                errors.append("\(show.title): \(error.localizedDescription)")
            }
        }

        loadSubscriptions()
        isRefreshing = false
        if !errors.isEmpty {
            refreshError = errors.prefix(3).joined(separator: "\n")
        }
    }

    // MARK: - Playback Position

    func savePlaybackPosition(for episode: PodcastEpisode, position: TimeInterval, completed: Bool = false) {
        try? store.savePlaybackPosition(
            episodeID: episode.id,
            showFeedURL: episode.showID,
            position: position,
            completed: completed
        )
    }

    func playbackPosition(for episode: PodcastEpisode) -> TimeInterval {
        (try? store.playbackPosition(episodeID: episode.id, showFeedURL: episode.showID)) ?? 0
    }

    func inProgressEpisodes() -> [PodcastStore.InProgressEpisode] {
        (try? store.inProgressEpisodes()) ?? []
    }

    // MARK: - Discover

    /// Try to discover a podcast from a URL (could be a direct RSS feed or a website).
    static func discover(from url: URL) async throws -> PodcastShow {
        let (show, _) = try await RSSPodcastParser.fetchFeed(url: url)
        return show
    }

    /// Search for podcasts using the iTunes Search API.
    static func searchPodcasts(query: String, limit: Int = 20) async throws -> [PodcastDiscoverResult] {
        guard !query.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "media", value: "podcast"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "entity", value: "podcast"),
        ]

        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(iTunesSearchResponse.self, from: data)

        return response.results.compactMap { result -> PodcastDiscoverResult? in
            guard let feedURL = result.feedURL, RSSPodcastParser.isHTTPURL(feedURL) else {
                return nil
            }
            var imageURL: URL?
            if let urlString = result.artworkURL600 ?? result.artworkURL100,
               RSSPodcastParser.isHTTPURL(urlString) {
                imageURL = URL(string: urlString)
            }

            let show = PodcastShow(
                id: feedURL,
                title: result.collectionName ?? result.trackName ?? "Unknown",
                author: result.artistName,
                description: result.collectionDescription ?? result.trackDescription,
                imageURL: imageURL,
                category: result.primaryGenreName,
                explicit: result.collectionExplicitness == "explicit",
                link: (result.collectionViewURL ?? result.trackViewURL).flatMap { URL(string: $0) },
                feedURL: feedURL
            )

            return PodcastDiscoverResult(id: feedURL, show: show, source: "directory")
        }
    }

    /// Popular podcasts — iTunes search with a broad term returns ranked results.
    static func topPodcasts(limit: Int = 50) async throws -> [PodcastDiscoverResult] {
        // The old rss.itunes.apple.com charts feed is retired. A broad search
        // still returns a useful popular set with real feed URLs.
        let queries = ["podcast", "news", "comedy", "technology"]
        var seen = Set<String>()
        var results: [PodcastDiscoverResult] = []
        for query in queries {
            let batch = try await searchPodcasts(query: query, limit: min(25, limit))
            for item in batch where seen.insert(item.id).inserted {
                results.append(item)
                if results.count >= limit { return results }
            }
        }
        return results
    }

    static func httpURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RSSPodcastParser.isHTTPURL(trimmed) else { return nil }
        return URL(string: trimmed)
    }
}

// MARK: - iTunes Search API Response

private struct iTunesSearchResponse: Decodable {
    let results: [iTunesPodcastResult]
}

private struct iTunesPodcastResult: Decodable {
    let collectionId: Int?
    let collectionName: String?
    let trackName: String?
    let artistName: String?
    let collectionDescription: String?
    let trackDescription: String?
    let artworkURL600: String?
    let artworkURL100: String?
    let feedURL: String?
    let collectionViewURL: String?
    let trackViewURL: String?
    let primaryGenreName: String?
    let collectionExplicitness: String?

    enum CodingKeys: String, CodingKey {
        case collectionId, collectionName, trackName, artistName
        case collectionDescription, trackDescription
        case artworkURL600 = "artworkUrl600"
        case artworkURL100 = "artworkUrl100"
        // iTunes uses "Url" (lowercase L), not Swift's "URL".
        case feedURL = "feedUrl"
        case collectionViewURL = "collectionViewUrl"
        case trackViewURL = "trackViewUrl"
        case primaryGenreName, collectionExplicitness
    }
}
