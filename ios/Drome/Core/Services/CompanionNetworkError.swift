import Foundation

/// Short, actionable reasons for companion (wishlist / Connect) failures.
enum CompanionNetworkError {
    /// One-line reason for Daily Mix / Home / Connect UI.
    static func shortReason(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return "You're offline"
            case .cannotFindHost, .dnsLookupFailed:
                return "Can't resolve companion host"
            case .cannotConnectToHost, .timedOut:
                return "Can't reach companion host"
            default:
                break
            }
        }

        if let wishlist = error as? DromeWishlistClient.WishlistError {
            switch wishlist {
            case .notConfigured:
                return wishlist.localizedDescription
            case .server(let message):
                return authOrServerReason(message)
            }
        }

        if let connect = error as? DromeConnectClient.ConnectError {
            switch connect {
            case .notConfigured:
                return connect.localizedDescription
            case .server(let message):
                return authOrServerReason(message)
            }
        }

        let text = error.localizedDescription
        if looksLikeAuth(text) {
            return text
        }
        if looksLikeUnreachable(text) {
            return "Can't reach companion host"
        }
        return text.isEmpty ? "Companion server error" : text
    }

    /// Extra caption under Connect's server status (nil = none).
    static func connectHelpCaption(for error: Error) -> String? {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .dnsLookupFailed,
                 .cannotConnectToHost, .timedOut:
                return nil
            default:
                break
            }
        }
        if let connect = error as? DromeConnectClient.ConnectError,
           case .server(let message) = connect,
           looksLikeAuth(message) || message.contains("401") || message.contains("403") {
            return nil
        }
        let text = error.localizedDescription
        if looksLikeAuth(text) || looksLikeUnreachable(text) {
            return nil
        }
        return "If this keeps happening, rebuild/restart the companion (`docker compose up -d --build`) using the same URL as Wishlist."
    }

    private static func authOrServerReason(_ message: String) -> String {
        if looksLikeAuth(message) {
            return message
        }
        if message.contains("401") || message.localizedCaseInsensitiveContains("unauthorized") {
            return message
        }
        if message.contains("HTTP") {
            return "Server error"
        }
        return message.isEmpty ? "Server error" : message
    }

    private static func looksLikeAuth(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("auth")
            || lower.contains("credential")
            || lower.contains("password")
            || lower.contains("unauthorized")
            || lower.contains("forbidden")
            || lower.contains("login")
    }

    private static func looksLikeUnreachable(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("could not be found")
            || lower.contains("hostname")
            || lower.contains("dns")
            || lower.contains("not connected")
            || lower.contains("network connection was lost")
            || lower.contains("timed out")
            || lower.contains("cannot connect")
            || lower.contains("couldn’t connect")
            || lower.contains("couldn't connect")
            || lower.contains("a server with the specified hostname")
    }
}
