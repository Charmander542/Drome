import Foundation

/// Minimal client for the public LRCLIB API (https://lrclib.net), used as the
/// fallback source for synced lyrics when Navidrome has none.
struct LRCLIBClient {
    struct Result: Decodable {
        var id: Int?
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Exact match by artist/title/duration; falls back to a fuzzy search and
    /// picks the closest duration match within 5 seconds.
    func lyrics(artist: String, title: String, album: String?, duration: Int?) async throws -> Result? {
        if let exact = try? await get(artist: artist, title: title, album: album, duration: duration),
           exact.syncedLyrics != nil || exact.plainLyrics != nil {
            return exact
        }
        return try await search(artist: artist, title: title, duration: duration)
    }

    private func get(artist: String, title: String, album: String?, duration: Int?) async throws -> Result? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        if let duration {
            items.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        components.queryItems = items
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(Result.self, from: data)
    }

    private func search(artist: String, title: String, duration: Int?) async throws -> Result? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        let results = try JSONDecoder().decode([Result].self, from: data)

        guard let duration else { return results.first }
        return results
            .filter { abs(($0.duration ?? 0) - Double(duration)) <= 5 }
            .sorted { abs(($0.duration ?? 0) - Double(duration)) < abs(($1.duration ?? 0) - Double(duration)) }
            .first ?? results.first
    }
}
