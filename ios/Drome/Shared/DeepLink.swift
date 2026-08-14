import Foundation

/// Opens `drome://track/{id}` and HTTPS share cards (`/s/{token}?song=`).
enum DeepLink {
    static func songID(from url: URL) -> String? {
        if url.scheme == "drome" {
            guard url.host == "track" else { return nil }
            let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return id.isEmpty ? nil : id
        }
        if let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let song = items.first(where: { $0.name == "song" })?.value,
           !song.isEmpty {
            return song
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
}
