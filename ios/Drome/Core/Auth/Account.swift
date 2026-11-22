import Foundation

/// A saved Navidrome login. Multiple accounts can exist on one device; all
/// per-user state (ratings, playlists, rotation) lives server-side or is
/// scoped by this account, so switching accounts is instant and independent.
struct Account: Codable, Identifiable, Hashable {
    let id: UUID
    var serverURL: URL
    var username: String
    var allowSelfSigned: Bool
    var wishlistURL: URL?
    /// Optional LAN / home URL. When reachable, preferred over `serverURL`.
    var homeURL: URL?
    /// Custom HTTP headers (Cloudflare Access, reverse proxies).
    var customHeaders: [String: String]

    init(id: UUID = UUID(), serverURL: URL, username: String,
         allowSelfSigned: Bool = false, wishlistURL: URL? = nil,
         homeURL: URL? = nil, customHeaders: [String: String] = [:]) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.allowSelfSigned = allowSelfSigned
        self.wishlistURL = wishlistURL
        self.homeURL = homeURL
        self.customHeaders = customHeaders
    }

    enum CodingKeys: String, CodingKey {
        case id, serverURL, username, allowSelfSigned, wishlistURL, homeURL, customHeaders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        serverURL = try c.decode(URL.self, forKey: .serverURL)
        username = try c.decode(String.self, forKey: .username)
        allowSelfSigned = try c.decodeIfPresent(Bool.self, forKey: .allowSelfSigned) ?? false
        wishlistURL = try c.decodeIfPresent(URL.self, forKey: .wishlistURL)
        homeURL = try c.decodeIfPresent(URL.self, forKey: .homeURL)
        customHeaders = try c.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
    }

    /// Prefer home URL when set; callers that probe reachability may swap.
    var effectiveServerURL: URL { homeURL ?? serverURL }

    /// Scopes content caches (lyrics, downloads) that are shared by every
    /// account on the same server, since Subsonic ids are server-wide.
    var serverKey: String {
        serverURL.host ?? serverURL.absoluteString
    }

    /// Scopes per-user state such as rotation overrides.
    var userKey: String {
        "\(serverKey)/\(username)"
    }

    var displayName: String {
        "\(username) @ \(serverKey)"
    }

    /// Public Navidrome playground (`demo` / `demo`) — streaming only, no companion.
    var isPublicDemo: Bool {
        let host = (serverURL.host ?? "").lowercased()
        return host == "demo.navidrome.org" && username.lowercased() == "demo"
    }

    static let publicDemoServerURL = URL(string: "https://demo.navidrome.org")!
    static let publicDemoUsername = "demo"
    static let publicDemoPassword = "demo"
}
