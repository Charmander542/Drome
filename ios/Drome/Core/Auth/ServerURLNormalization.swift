import Foundation

/// Shared URL cleanup for Navidrome / companion fields on Login and Settings.
/// Defaults missing schemes to HTTPS so Subsonic tokens aren't sent in cleartext;
/// explicit `http://` (LAN) still works.
enum ServerURLNormalization {
    /// Default request timeout for companion wishlist/connect GETs.
    static let companionGETTimeout: TimeInterval = 25

    static func normalize(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else { return nil }
        // Strip trailing slash from path for cleaner base URLs.
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}
