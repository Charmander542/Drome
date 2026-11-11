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

    /// Exact match by artist/title/duration; falls back to a scored search that
    /// still requires a title/artist identity match (never “first result wins”).
    func lyrics(artist: String, title: String, album: String?, duration: Int?) async throws -> Result? {
        var candidates: [Result] = []

        if let exact = try? await get(artist: artist, title: title, album: album, duration: duration),
           exact.syncedLyrics != nil || exact.plainLyrics != nil,
           identityMatches(requestedTitle: title, requestedArtist: artist, result: exact) {
            candidates.append(exact)
        }

        if let searched = try? await searchAll(artist: artist, title: title) {
            candidates.append(contentsOf: searched.filter {
                identityMatches(requestedTitle: title, requestedArtist: artist, result: $0)
                    && ($0.syncedLyrics?.isEmpty == false || $0.plainLyrics?.isEmpty == false)
            })
        }

        return pickBest(from: candidates, album: album, duration: duration)
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

    private func searchAll(artist: String, title: String) async throws -> [Result] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        let (data, response) = try await session.data(from: components.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        return try JSONDecoder().decode([Result].self, from: data)
    }

    /// Prefer synced + closest duration + album match. Reject wild duration
    /// mismatches when a better alternative exists (radio edit vs album cut).
    private func pickBest(from results: [Result], album: String?, duration: Int?) -> Result? {
        guard !results.isEmpty else { return nil }

        // De-dupe by id / content fingerprint.
        var seen = Set<String>()
        let unique = results.filter { result in
            let key = result.id.map(String.init)
                ?? "\(result.trackName ?? "")|\(result.artistName ?? "")|\(result.duration ?? 0)|\(result.syncedLyrics?.count ?? 0)"
            return seen.insert(key).inserted
        }

        func score(_ result: Result) -> Double {
            var s = 0.0
            if result.syncedLyrics?.isEmpty == false { s += 100 }
            else if result.plainLyrics?.isEmpty == false { s += 10 }

            if let duration, let remote = result.duration, remote > 0 {
                let delta = abs(remote - Double(duration))
                if delta <= 1.5 { s += 40 }
                else if delta <= 3 { s += 25 }
                else if delta <= 5 { s += 10 }
                else if delta <= 8 { s += 2 }
                else { s -= 40 }
                // Soft preference for closer durations.
                s -= delta * 1.5
            }

            if let album, !album.isEmpty,
               titlesMatch(album, result.albumName ?? "") {
                s += 12
            }

            if result.instrumental == true { s -= 20 }
            return s
        }

        let ranked = unique.sorted { score($0) > score($1) }
        guard let best = ranked.first else { return nil }

        // If the winner's duration is way off and we have a closer synced hit, prefer that.
        if let duration,
           let remote = best.duration,
           abs(remote - Double(duration)) > 8,
           let closer = ranked.first(where: {
               $0.syncedLyrics?.isEmpty == false
                   && abs(($0.duration ?? 0) - Double(duration)) <= 5
           }) {
            return closer
        }
        return best
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
