import Foundation

struct WishlistEntry: Codable, Identifiable, Hashable {
    let id: Int64
    var owner: String
    var kind: String
    var spotifyId: String
    var spotifyUrl: String
    var title: String
    var artist: String
    var album: String
    var coverUrl: String
    var acquired: Bool
    var status: String?
    var statusMessage: String?
    var createdAt: String?
    var sourcePlaylistId: String?
    var sourcePlaylistName: String?
    var sharedWith: [String]?
    var sharedBy: String?
}

struct SpotifySearchHit: Codable, Identifiable, Hashable {
    var kind: String
    var spotifyId: String
    var spotifyUrl: String
    var title: String
    var artist: String
    var album: String
    var coverUrl: String
    var trackCount: Int?

    var id: String { "\(kind):\(spotifyId)" }
}

struct WishlistPlaylistImport: Codable {
    var kind: String?
    var playlistId: String?
    var playlistName: String?
    var added: Int
    var skippedOwned: Int
    var entries: [WishlistEntry]
    var sourcePlaylistId: String?
    var sourcePlaylistName: String?
    var failed: [String]?
}

enum WishlistAddResult {
    case entry(WishlistEntry)
    case playlist(WishlistPlaylistImport)
}

/// Client for the Drome companion server. Authentication reuses the same
/// Subsonic token credentials; the companion verifies them against Navidrome.
struct DromeWishlistClient {
    enum WishlistError: LocalizedError {
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "No companion server configured. Set its URL in Settings."
            case .server(let message):
                return message
            }
        }
    }

    private struct ServerError: Decodable {
        var error: String?
    }

    struct EmptyWishlistResponse: Decodable {}

    let baseURL: URL
    let session: URLSession
    /// Provides fresh Subsonic auth query items (u/t/s and friends).
    let authItems: () -> [URLQueryItem]

    private func url(_ path: String, extraQuery: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WishlistError.notConfigured
        }
        var base = components.path
        if base.hasSuffix("/") { base.removeLast() }
        components.path = base + path
        var items = authItems().filter { ["u", "t", "s"].contains($0.name) }
        items.append(contentsOf: extraQuery)
        components.queryItems = items
        guard let url = components.url else { throw WishlistError.notConfigured }
        return url
    }

    private func sendRaw(path: String, method: String,
                         extraQuery: [URLQueryItem] = [],
                         body: (some Encodable)? = Optional<Int>.none) async throws -> (Data, Int) {
        var request = URLRequest(url: try url(path, extraQuery: extraQuery))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data))?.error
            throw WishlistError.server(message ?? "Companion server error (HTTP \(status)).")
        }
        return (data, status)
    }

    private func send<T: Decodable>(_ type: T.Type, path: String, method: String,
                                    extraQuery: [URLQueryItem] = [],
                                    body: (some Encodable)? = Optional<Int>.none) async throws -> T {
        let (data, _) = try await sendRaw(path: path, method: method, extraQuery: extraQuery, body: body)
        if T.self == EmptyWishlistResponse.self {
            return EmptyWishlistResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func list() async throws -> [WishlistEntry] {
        struct ListResponse: Decodable { var entries: [WishlistEntry] }
        return try await send(ListResponse.self, path: "/wishlist", method: "GET").entries
    }

    func search(query: String, types: String = "track,album,playlist", limit: Int = 10) async throws -> [SpotifySearchHit] {
        struct SearchResponse: Decodable { var results: [SpotifySearchHit] }
        return try await send(
            SearchResponse.self,
            path: "/spotify/search",
            method: "GET",
            extraQuery: [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: types),
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 10))),
            ]
        ).results
    }

    /// Track-focused search used by missing-track recommend UIs.
    func searchSpotify(query: String, limit: Int = 10) async throws -> [SpotifySearchHit] {
        try await search(query: query, types: "track", limit: limit)
    }

    func artistImageURL(name: String) async throws -> String {
        struct Response: Decodable { var imageUrl: String }
        return try await send(Response.self, path: "/spotify/artist-image", method: "GET",
                              extraQuery: [URLQueryItem(name: "name", value: name)]).imageUrl
    }

    func add(spotifyLink: String) async throws -> WishlistAddResult {
        struct Body: Encodable { var url: String }
        let (data, _) = try await sendRaw(path: "/wishlist", method: "POST", body: Body(url: spotifyLink))
        return try decodeAddResult(from: data)
    }

    /// Paste one or many Spotify links (tracks, albums, playlists).
    func add(spotifyLinks: [String]) async throws -> WishlistAddResult {
        let cleaned = spotifyLinks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw WishlistError.server("No Spotify links to import.")
        }
        if cleaned.count == 1 {
            return try await add(spotifyLink: cleaned[0])
        }
        struct Body: Encodable { var urls: [String] }
        let (data, _) = try await sendRaw(path: "/wishlist", method: "POST", body: Body(urls: cleaned))
        return try decodeAddResult(from: data)
    }

    private func decodeAddResult(from data: Data) throws -> WishlistAddResult {
        if let importResult = try? JSONDecoder().decode(WishlistPlaylistImport.self, from: data),
           importResult.kind == "playlistImport" {
            return .playlist(importResult)
        }
        let entry = try JSONDecoder().decode(WishlistEntry.self, from: data)
        return .entry(entry)
    }

    func delete(id: Int64) async throws {
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/\(id)", method: "DELETE")
    }

    func deleteSourcePlaylist(id: String) async throws {
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/source/\(id)", method: "DELETE")
    }

    func setAcquired(id: Int64, acquired: Bool) async throws {
        struct Body: Encodable { var acquired: Bool }
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/\(id)", method: "PATCH",
                           body: Body(acquired: acquired))
    }

    func share(id: Int64, with user: String, remove: Bool = false) async throws {
        struct Body: Encodable { var user: String; var remove: Bool }
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/\(id)/share", method: "POST",
                           body: Body(user: user, remove: remove))
    }

    func shareList(with user: String, remove: Bool = false) async throws {
        struct Body: Encodable { var user: String; var remove: Bool }
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/share", method: "POST",
                           body: Body(user: user, remove: remove))
    }

    struct TrackShareResponse: Decodable {
        var url: String
        var token: String?
        var coverUrl: String?
    }

    func createTrackShare(songId: String, title: String, artist: String, album: String,
                          accent: String, coverJPEG: Data?) async throws -> URL {
        struct Body: Encodable {
            var songId: String
            var title: String
            var artist: String
            var album: String
            var accent: String
            var coverJpegBase64: String?
        }
        let body = Body(
            songId: songId, title: title, artist: artist, album: album, accent: accent,
            coverJpegBase64: coverJPEG?.base64EncodedString())
        let created = try await send(TrackShareResponse.self, path: "/share/track", method: "POST", body: body)
        guard let url = URL(string: created.url) else {
            throw WishlistError.server("Companion server returned an invalid share URL.")
        }
        return url
    }
}
