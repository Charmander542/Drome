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
    var createdAt: String?
    var sharedWith: [String]?
    var sharedBy: String?
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

    private func url(_ path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WishlistError.notConfigured
        }
        var base = components.path
        if base.hasSuffix("/") { base.removeLast() }
        components.path = base + path
        components.queryItems = authItems().filter { ["u", "t", "s"].contains($0.name) }
        guard let url = components.url else { throw WishlistError.notConfigured }
        return url
    }

    private func send<T: Decodable>(_ type: T.Type, path: String, method: String,
                                    body: (some Encodable)? = Optional<Int>.none) async throws -> T {
        var request = URLRequest(url: try url(path))
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
        if T.self == EmptyWishlistResponse.self {
            return EmptyWishlistResponse() as! T
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func list() async throws -> [WishlistEntry] {
        struct ListResponse: Decodable { var entries: [WishlistEntry] }
        return try await send(ListResponse.self, path: "/wishlist", method: "GET").entries
    }

    func add(spotifyLink: String) async throws -> WishlistEntry {
        struct Body: Encodable { var url: String }
        return try await send(WishlistEntry.self, path: "/wishlist", method: "POST",
                              body: Body(url: spotifyLink))
    }

    func delete(id: Int64) async throws {
        _ = try await send(EmptyWishlistResponse.self, path: "/wishlist/\(id)", method: "DELETE")
    }

    func setAcquired(id: Int64, acquired: Bool) async throws {
        struct Body: Encodable { var acquired: Bool }
        _ = try await send(WishlistEntry.self, path: "/wishlist/\(id)", method: "PATCH",
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
}
