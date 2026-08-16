import Foundation

/// Opens `drome://track/{id}` and HTTPS share cards (`/s/{token}?song=`).
enum DeepLink {
    static func songID(from url: URL) -> String? {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let song = items.first(where: { $0.name == "song" })?.value, !song.isEmpty {
            return song.removingPercentEncoding ?? song
        }
        if url.scheme == "drome" {
            if url.host == "track" {
                let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if !id.isEmpty { return id.removingPercentEncoding ?? id }
            }
            let last = url.lastPathComponent
            if !last.isEmpty, last != "/", last != "track", last != "imessage", last != url.host {
                return last.removingPercentEncoding ?? last
            }
        }
        return nil
    }

    static func isShareCard(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.first == "s", parts.count >= 2 else { return false }
        return parts.last != "cover"
    }

    @MainActor
    static func open(_ url: URL, env: AppEnvironment) {
        env.handleDeepLink(url)
    }

    @MainActor
    static func consumePending(env: AppEnvironment) {
        env.consumePendingOpen()
    }
}
