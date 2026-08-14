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

    /// Exact match by artist/title/duration; falls back to a fuzzy search that
    /// still requires a title/artist identity match (never “first result wins”).
    func lyrics(artist: String, title: String, album: String?, duration: Int?) async throws -> Result? {
        if let exact = try? await get(artist: artist, title: title, album: album, duration: duration),
           exact.syncedLyrics != nil || exact.plainLyrics != nil,
           identityMatches(requestedTitle: title, requestedArtist: artist, result: exact) {
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

        // Short / numeric titles (e.g. "2007") return lots of junk — only keep
        // hits whose track + artist actually match what we asked for.
        let matched = results.filter {
            identityMatches(requestedTitle: title, requestedArtist: artist, result: $0)
                && ($0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false)
        }
        guard !matched.isEmpty else { return nil }

        guard let duration else { return matched.first }
        return matched
            .filter { abs(($0.duration ?? 0) - Double(duration)) <= 5 }
            .sorted { abs(($0.duration ?? 0) - Double(duration)) < abs(($1.duration ?? 0) - Double(duration)) }
            .first ?? matched.first
    }

    private func identityMatches(requestedTitle: String, requestedArtist: String, result: Result) -> Bool {
        titlesMatch(requestedTitle, result.trackName ?? "")
            && (requestedArtist.isEmpty || titlesMatch(requestedArtist, result.artistName ?? ""))
    }

    /// Loose identity compare: ignore case, diacritics, and punctuation so
    /// "2007" ≠ "Something 2007 Remix" unless one contains the other cleanly.
    private func titlesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        // Require the shorter token to be a whole-string match for tiny titles
        // like "2007" — containing "2007" inside a longer unrelated title is OK
        // only when lengths are close (avoid year-in-title false friends).
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        if shorter.count <= 4 {
            return longer == shorter || longer.hasPrefix(shorter) || longer.hasSuffix(shorter)
        }
        return longer.contains(shorter)
    }

    private func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
