import Foundation

/// Opens `drome://track/{id}`, `drome://play?resume=…`, and HTTPS share cards.
enum DeepLink {
    struct ContextPlay {
        var resumeKey: String
        var entryId: String
        var songId: String?
    }

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

    static func contextPlay(from url: URL) -> ContextPlay? {
        guard url.scheme == "drome", url.host == "play" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let resume = items.first(where: { $0.name == "resume" })?.value,
              let entry = items.first(where: { $0.name == "entry" })?.value
        else { return nil }
        let song = items.first(where: { $0.name == "song" })?.value
        return ContextPlay(
            resumeKey: resume.removingPercentEncoding ?? resume,
            entryId: entry.removingPercentEncoding ?? entry,
            songId: song?.removingPercentEncoding ?? song)
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
