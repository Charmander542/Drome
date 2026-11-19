import Foundation

/// Per-listener taste signals for shared Navidrome libraries.
///
/// Unrated / high-play-count tracks on a multi-user server are often someone
/// else's favorites. Once this user has rated enough songs, we treat unrated
/// catalog as weak unless genre/artist matches their recent seeds or top ratings.
struct TasteAffinity: Sendable {
    /// Normalized genre keys this listener gravitates toward.
    let preferredGenres: Set<String>
    /// Artist IDs from seeds / high-rated context.
    let preferredArtistIDs: Set<String>
    /// How many songs this user has rated (any stars).
    let ratedCount: Int
    /// Count of 4–5★ ratings — stronger taste signal.
    let lovedCount: Int

    /// Enough signal to stop treating the whole catalog as “neutral 3★”.
    var isEstablished: Bool {
        lovedCount >= 5 || ratedCount >= 12
    }

    static let empty = TasteAffinity(
        preferredGenres: [], preferredArtistIDs: [], ratedCount: 0, lovedCount: 0)

    static func build(
        ratings: [String: Int],
        seeds: [Song],
        knownSongs: [Song] = []
    ) -> TasteAffinity {
        var genres = Set<String>()
        var artists = Set<String>()

        for song in seeds {
            if let g = normalizeGenre(song.genre) { genres.insert(g) }
            if let id = song.artistId, !id.isEmpty { artists.insert(id) }
        }

        // Pull genres/artists from rated songs when we have metadata on hand.
        let byID = Dictionary(uniqueKeysWithValues: (seeds + knownSongs).map { ($0.id, $0) })
        for (id, rating) in ratings where rating >= 4 {
            guard let song = byID[id] else { continue }
            if let g = normalizeGenre(song.genre) { genres.insert(g) }
            if let artistID = song.artistId, !artistID.isEmpty { artists.insert(artistID) }
        }

        let ratedCount = ratings.values.filter { $0 > 0 }.count
        let lovedCount = ratings.values.filter { $0 >= 4 }.count
        return TasteAffinity(
            preferredGenres: genres,
            preferredArtistIDs: artists,
            ratedCount: ratedCount,
            lovedCount: lovedCount)
    }

    func matches(_ song: Song) -> Bool {
        if let id = song.artistId, preferredArtistIDs.contains(id) { return true }
        if let g = Self.normalizeGenre(song.genre), preferredGenres.contains(g) { return true }
        return false
    }

    /// Effective star weight for shuffle / autoplay. Unrated off-taste songs
    /// collapse toward ~1★ so household additions don't dominate.
    func effectiveRating(for song: Song, raw: Int) -> Double {
        if raw > 0 { return Double(raw) }
        guard isEstablished else { return 3 }
        if matches(song) { return 2.4 }
        return 1.15
    }

    /// Play-count multiplier. Shared-server counters mix every listener — only
    /// trust them when taste is cold or the track already matches this user.
    func playCountFactor(for song: Song, rawRating: Int) -> Double {
        let plays = Double(song.playCount ?? 0)
        let base = log2(2.0 + plays)
        guard isEstablished else { return base }
        if rawRating > 0 || matches(song) { return base }
        return 1.0 + (base - 1.0) * 0.12
    }

    static func normalizeGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
