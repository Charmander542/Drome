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
        /// Site badge "Word Synced" — word timings live in `lyricsfile`, not
        /// Enhanced LRC inside `syncedLyrics` (that field stays line-only).
        var hasWordSync: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
        var lyricsfile: String?
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
           hasUsableLyrics(exact),
           identityMatches(requestedTitle: title, requestedArtist: artist, result: exact) {
            candidates.append(exact)
        }

        if let searched = try? await searchAll(artist: artist, title: title) {
            candidates.append(contentsOf: searched.filter {
                identityMatches(requestedTitle: title, requestedArtist: artist, result: $0)
                    && hasUsableLyrics($0)
            })
        }

        guard var best = pickBest(from: candidates, album: album, duration: duration) else {
            return nil
        }
        // Surface Word Synced lyricsfile as Enhanced LRC so LRCParser lights
        // words; syncedLyrics alone is line karaoke even when hasWordSync.
        if let enhanced = Self.effectiveSyncedLyrics(best) {
            best.syncedLyrics = enhanced
        }
        return best
    }

    private func hasUsableLyrics(_ result: Result) -> Bool {
        if result.syncedLyrics?.isEmpty == false { return true }
        if result.plainLyrics?.isEmpty == false { return true }
        if result.lyricsfile?.isEmpty == false { return true }
        return false
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
                ?? "\(result.trackName ?? "")|\(result.artistName ?? "")|\(result.duration ?? 0)|\(result.syncedLyrics?.count ?? 0)|\(result.lyricsfile?.count ?? 0)"
            return seen.insert(key).inserted
        }

        func score(_ result: Result) -> Double {
            var s = 0.0
            if let synced = Self.effectiveSyncedLyrics(result), !synced.isEmpty {
                // Enhanced LRC / lyricsfile word stamps beat line-only karaoke.
                s += Self.hasWordSync(synced) ? 140 : 100
            } else if result.plainLyrics?.isEmpty == false {
                s += 10
            }

            if let duration, let remote = result.duration, remote > 0 {
                let delta = abs(remote - Double(duration))
                // Tight duration match — loose hits “sometimes” sync, then drift.
                if delta <= 1.0 { s += 50 }
                else if delta <= 2.0 { s += 35 }
                else if delta <= 3.5 { s += 15 }
                else if delta <= 5.0 { s += 2 }
                else { s -= 60 }
                s -= delta * 2.5
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

        // Prefer a closer synced hit whenever the winner’s duration is soft.
        if let duration,
           let remote = best.duration,
           abs(remote - Double(duration)) > 3.5,
           let closer = ranked.first(where: {
               Self.effectiveSyncedLyrics($0)?.isEmpty == false
                   && abs(($0.duration ?? 0) - Double(duration)) <= 3.0
           }) {
            return closer
        }
        // Refuse synced lyrics that are clearly a different cut — constant
        // wrong timing is worse than “no synced lyrics”.
        if let duration,
           let remote = best.duration,
           Self.effectiveSyncedLyrics(best)?.isEmpty == false,
           abs(remote - Double(duration)) > 6.0 {
            if let plain = ranked.first(where: {
                $0.plainLyrics?.isEmpty == false
                    && Self.effectiveSyncedLyrics($0) == nil
            }) {
                return plain
            }
        }
        return best
    }

    private func identityMatches(requestedTitle: String, requestedArtist: String, result: Result) -> Bool {
        titlesMatch(requestedTitle, result.trackName ?? "")
            && (requestedArtist.isEmpty || titlesMatch(requestedArtist, result.artistName ?? ""))
    }

    /// Identity compare: ignore case / diacritics / punctuation. Require near-
    /// equal length so short titles don’t match longer remixes via `contains`.
    private func titlesMatch(_ a: String, _ b: String) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        if na == nb { return true }
        let shorter = na.count <= nb.count ? na : nb
        let longer = na.count <= nb.count ? nb : na
        // Allow small suffix/prefix noise ("remastered") but not "love" ⊂ "lovelyday".
        guard shorter.count >= 5 else {
            return longer == shorter || longer.hasPrefix(shorter) || longer.hasSuffix(shorter)
        }
        guard longer.contains(shorter) else { return false }
        return Double(shorter.count) / Double(longer.count) >= 0.72
    }

    private func normalize(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Enhanced LRC uses `<mm:ss.xx>` (or ms) stamps before each word.
    static func hasWordSync(_ lrc: String) -> Bool {
        lrc.range(of: #"<\d{1,2}:\d{1,2}(?:[.:]\d{1,3})?>"#, options: .regularExpression) != nil
    }

    /// Prefer Word Synced `lyricsfile` YAML converted to Enhanced LRC; else
    /// line-level `syncedLyrics`.
    static func effectiveSyncedLyrics(_ result: Result) -> String? {
        if result.hasWordSync == true || !(result.lyricsfile?.isEmpty ?? true) {
            if let enhanced = lyricsFileToEnhancedLRC(result.lyricsfile ?? ""), !enhanced.isEmpty {
                return enhanced
            }
        }
        if let synced = result.syncedLyrics, !synced.isEmpty {
            return synced
        }
        return nil
    }

    /// Convert LRCLIB lyricsfile YAML into Enhanced LRC for `LRCParser`.
    static func lyricsFileToEnhancedLRC(_ raw: String) -> String? {
        let lines = parseLyricsFile(raw)
        guard !lines.isEmpty else { return nil }
        var out = ""
        var wordCount = 0
        for line in lines {
            if line.words.isEmpty {
                out += "[\(formatLRCStamp(line.startMs))] \(line.text.trimmingCharacters(in: .whitespaces))\n"
                continue
            }
            out += "[\(formatLRCStamp(line.startMs))]"
            for word in line.words where !word.text.isEmpty {
                wordCount += 1
                out += " <\(formatLRCStamp(word.startMs))>\(word.text)"
            }
            out += "\n"
        }
        return wordCount == 0 ? nil : out
    }

    private struct LyricsFileWord {
        var text: String
        var startMs: Int
    }

    private struct LyricsFileLine {
        var text: String
        var startMs: Int
        var words: [LyricsFileWord]
    }

    private static func parseLyricsFile(_ raw: String) -> [LyricsFileLine] {
        var out: [LyricsFileLine] = []
        var inWords = false

        for rawLine in raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = leadingSpaces(rawLine)

            if trimmed.hasPrefix("- text:") {
                let val = yamlScalar(String(trimmed.dropFirst("- text:".count)))
                if indent == 0 {
                    out.append(LyricsFileLine(text: val, startMs: 0, words: []))
                    inWords = false
                } else if inWords, !out.isEmpty {
                    out[out.count - 1].words.append(LyricsFileWord(text: val, startMs: 0))
                }
            } else if trimmed.hasPrefix("start_ms:") {
                guard let ms = yamlInt(String(trimmed.dropFirst("start_ms:".count))), !out.isEmpty else {
                    continue
                }
                if inWords, indent >= 4, !out[out.count - 1].words.isEmpty {
                    out[out.count - 1].words[out[out.count - 1].words.count - 1].startMs = ms
                } else {
                    out[out.count - 1].startMs = ms
                }
            } else if trimmed == "words:" || trimmed.hasPrefix("words:") {
                if !out.isEmpty { inWords = true }
            }
        }
        return out
    }

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        for ch in s {
            if ch == " " { n += 1; continue }
            if ch == "\t" { n += 2; continue }
            break
        }
        return n
    }

    private static func yamlScalar(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s == "null" || s == "~" { return "" }
        if s.count >= 2, s.first == "'", s.last == "'" {
            let inner = String(s.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        if s.count >= 2, s.first == "\"", s.last == "\"" {
            var inner = String(s.dropFirst().dropLast())
            inner = inner.replacingOccurrences(of: "\\\"", with: "\"")
            inner = inner.replacingOccurrences(of: "\\\\", with: "\\")
            return inner
        }
        return s
    }

    private static func yamlInt(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if let idx = s.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "#" }) {
            s = String(s[..<idx])
        }
        return Int(s)
    }

    /// Full millisecond precision — matches the companion sidecar writer.
    private static func formatLRCStamp(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let m = clamped / 60_000
        let s = (clamped % 60_000) / 1_000
        let frac = clamped % 1_000
        return String(format: "%02d:%02d.%03d", m, s, frac)
    }
}
