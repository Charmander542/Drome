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

    init(id: UUID = UUID(), serverURL: URL, username: String,
         allowSelfSigned: Bool = false, wishlistURL: URL? = nil) {
        self.id = id
        self.serverURL = serverURL
        self.username = username
        self.allowSelfSigned = allowSelfSigned
        self.wishlistURL = wishlistURL
    }

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
}
