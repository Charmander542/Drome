import Foundation

/// A single ranked search hit. Artists, albums, songs (and optional lyrics
/// matches) share one list sorted by how well they match the query.
struct SearchHit: Identifiable {
    enum Kind: String {
        case artist, album, song, lyrics
    }

    var id: String
    var kind: Kind
    var score: Double
    var title: String
    var subtitle: String
    var coverArt: String?

    var artist: Artist?
    var album: Album?
    var song: Song?
    var lyrics: LyricsSearchMatch?
}

enum SearchRanker {
    /// Build a flat, best-match-first list from Subsonic search3 (+ optional
    /// lyrics hits). Exact / prefix artist matches outrank song titles that
    /// merely contain the query — so "adele" surfaces Adele the artist first.
    static func rank(query: String,
                     result: SearchResult3,
                     lyrics: [LyricsSearchMatch] = []) -> [SearchHit] {
        let q = normalize(query)
        guard !q.isEmpty else { return [] }

        var hits: [SearchHit] = []

        for artist in result.artists {
            let score = matchScore(name: artist.name, query: q, kind: .artist)
            guard score > 0 else { continue }
            hits.append(SearchHit(
                id: "artist-\(artist.id)",
                kind: .artist,
                score: score,
                title: artist.name,
                subtitle: artist.albumCount.map { "\($0) albums · Artist" } ?? "Artist",
                coverArt: artist.coverArt ?? artist.id,
                artist: artist
            ))
        }

        for album in result.albums {
            let nameScore = matchScore(name: album.name, query: q, kind: .album)
            let artistScore = matchScore(name: album.artist ?? "", query: q, kind: .album) * 0.85
            let score = max(nameScore, artistScore)
            guard score > 0 else { continue }
            hits.append(SearchHit(
                id: "album-\(album.id)",
                kind: .album,
                score: score,
                title: album.name,
                subtitle: [album.artist, "Album"].compactMap { $0 }.joined(separator: " · "),
                coverArt: album.coverArt ?? album.id,
                album: album
            ))
        }

        for song in result.songs {
            let titleScore = matchScore(name: song.title, query: q, kind: .song)
            let artistScore = matchScore(name: song.artist ?? "", query: q, kind: .song) * 0.9
            let albumScore = matchScore(name: song.album ?? "", query: q, kind: .song) * 0.7
            let score = max(titleScore, artistScore, albumScore)
            guard score > 0 else { continue }
            let subtitle = [song.artist, song.album, "Song"]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
            hits.append(SearchHit(
                id: "song-\(song.id)",
                kind: .song,
                score: score,
                title: song.title,
                subtitle: subtitle,
                coverArt: song.coverArt ?? song.albumId,
                song: song
            ))
        }

        for lyric in lyrics {
            // Lyrics matches are useful but should sit below strong metadata hits.
            let titleScore = matchScore(name: lyric.title, query: q, kind: .lyrics)
            let artistScore = matchScore(name: lyric.artist, query: q, kind: .lyrics) * 0.8
            let lyricBonus: Double = lyric.snippet.localizedCaseInsensitiveContains(q) ? 120 : 40
            let score = max(titleScore, artistScore) + lyricBonus
            hits.append(SearchHit(
                id: "lyrics-\(lyric.songId)",
                kind: .lyrics,
                score: score,
                title: lyric.title,
                subtitle: "\(lyric.artist) · Lyrics",
                coverArt: nil,
                lyrics: lyric
            ))
        }

        // Stable sort: score desc, then kind priority (artist > album > song > lyrics), then title.
        return hits.sorted { a, b in
            if abs(a.score - b.score) > 0.5 { return a.score > b.score }
            let kindOrder: [SearchHit.Kind: Int] = [.artist: 0, .album: 1, .song: 2, .lyrics: 3]
            let ka = kindOrder[a.kind] ?? 9
            let kb = kindOrder[b.kind] ?? 9
            if ka != kb { return ka < kb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    // MARK: - Scoring

    /// Higher is better. Kind weights push artists above songs for the same
    /// textual match quality (exact "Adele" artist >> song titled "Adele").
    private static func matchScore(name: String, query: String, kind: SearchHit.Kind) -> Double {
        let n = normalize(name)
        guard !n.isEmpty, !query.isEmpty else { return 0 }

        let kindWeight: Double
        switch kind {
        case .artist: kindWeight = 1.45
        case .album: kindWeight = 1.15
        case .song: kindWeight = 1.0
        case .lyrics: kindWeight = 0.75
        }

        // Exact equality — "adele" → Adele
        if n == query {
            return 1000 * kindWeight
        }

        // Starts with query — "adele" → Adele Adkins (rare) / "hello"
        if n.hasPrefix(query) {
            // Shorter names that prefix-match are better (Adele beats Adele Something Long)
            let lengthPenalty = Double(n.count - query.count) * 2
            return (820 - lengthPenalty) * kindWeight
        }

        // Query starts with the name (user typed more than the name)
        if query.hasPrefix(n), n.count >= 3 {
            return 780 * kindWeight
        }

        // Word-boundary token match — "rolling stones" in "The Rolling Stones"
        let nameTokens = tokens(n)
        let queryTokens = tokens(query)
        if !queryTokens.isEmpty, queryTokens.allSatisfy({ qt in nameTokens.contains(where: { $0 == qt || $0.hasPrefix(qt) }) }) {
            let exactTokens = queryTokens.filter { nameTokens.contains($0) }.count
            return (640 + Double(exactTokens) * 40) * kindWeight
        }

        // Substring contains
        if n.contains(query) {
            return 420 * kindWeight
        }

        // Fuzzy: all query chars appear in order (very weak)
        if subsequence(query, in: n) {
            return 80 * kindWeight
        }

        return 0
    }

    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func subsequence(_ needle: String, in haystack: String) -> Bool {
        var i = haystack.startIndex
        for ch in needle {
            guard let found = haystack[i...].firstIndex(of: ch) else { return false }
            i = haystack.index(after: found)
        }
        return true
    }
}
