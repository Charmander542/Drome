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

    /// Listening memory with a half-life, so old phases fade and recent ones lead.
    let memory: ListenerMemory

    /// Enough signal to stop treating the whole catalog as “neutral 3★”.
    var isEstablished: Bool {
        lovedCount >= 5 || ratedCount >= 12 || memory.hasSignal
    }

    static let empty = TasteAffinity(
        preferredGenres: [], preferredArtistIDs: [], ratedCount: 0, lovedCount: 0,
        memory: .empty)

    static func build(
        ratings: [String: Int],
        seeds: [Song],
        knownSongs: [Song] = [],
        memory: ListenerMemory = .empty
    ) -> TasteAffinity {
        var genres = Set<String>()
        var artists = Set<String>()

        for song in seeds {
            if let g = normalizeGenre(song.genre) { genres.insert(g) }
            if let id = song.artistId, !id.isEmpty { artists.insert(id) }
        }

        // Pull genres/artists from rated songs when we have metadata on hand.
        // Seeds often reappear in similar/random batches — never trap on dup IDs.
        let byID = Dictionary(
            (seeds + knownSongs).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first })
        for (id, rating) in ratings where rating >= 4 {
            guard let song = byID[id] else { continue }
            if let g = normalizeGenre(song.genre) { genres.insert(g) }
            if let artistID = song.artistId, !artistID.isEmpty { artists.insert(artistID) }
        }

        let genrePeak = memory.genre.values.max() ?? 0
        if genrePeak > 0 {
            for (name, weight) in memory.genre where weight >= genrePeak * 0.35 {
                genres.insert(name)
            }
        }
        let artistPeak = memory.artist.values.max() ?? 0
        if artistPeak > 0 {
            for (id, weight) in memory.artist where weight >= artistPeak * 0.35 {
                artists.insert(id)
            }
        }

        let ratedCount = ratings.values.filter { $0 > 0 }.count
        let lovedCount = ratings.values.filter { $0 >= 4 }.count
        return TasteAffinity(
            preferredGenres: genres,
            preferredArtistIDs: artists,
            ratedCount: ratedCount,
            lovedCount: lovedCount,
            memory: memory)
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
        let affinity = memory.affinity(genre: Self.normalizeGenre(song.genre), artist: song.artistId)
        if affinity > 0.12 { return 1.15 + affinity * 2.7 }
        if matches(song) { return 2.2 }
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
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Curated name ("Jazz") so radio neighbors and Navidrome genre pulls agree.
        return GenreNormalizer.shared.normalize(trimmed) ?? trimmed
    }
}

/// Implicit taste from what this listener actually finishes and rates.
///
/// Confidence grows with repeats and decays with a three-week half-life, the
/// same shape as implicit-feedback recommenders (plays are confidence, not a
/// rating). Shared-library play counts stay out of this — only this phone's
/// history is counted.
struct ListenerMemory: Sendable {
    var genre: [String: Double]
    var artist: [String: Double]
    /// Decayed mass of positive observations. Cold start stays neutral below ~6.
    var mass: Double
    var updatedAt: TimeInterval

    static let halfLife: TimeInterval = 21 * 24 * 3600
    static let empty = ListenerMemory(genre: [:], artist: [:], mass: 0, updatedAt: 0)

    var hasSignal: Bool { mass >= 6 }

    mutating func observe(genre name: String?, artist artistID: String?, amount: Double, at: TimeInterval) {
        decay(to: at)
        if amount >= 0 {
            if let name, !name.isEmpty { genre[name, default: 0] += amount }
            if let artistID, !artistID.isEmpty { artist[artistID, default: 0] += amount }
            mass += amount
        } else {
            let cut = -amount
            if let name, !name.isEmpty { genre[name] = max(0, (genre[name] ?? 0) - cut) }
            if let artistID, !artistID.isEmpty { artist[artistID] = max(0, (artist[artistID] ?? 0) - cut) }
        }
        prune()
    }

    /// 0 when we have never heard this corner of the library, 1 at the peak.
    func affinity(genre name: String?, artist artistID: String?) -> Double {
        let genreScore = name.flatMap { genre[$0] } ?? 0
        let artistScore = artistID.flatMap { artist[$0] } ?? 0
        let genrePeak = genre.values.max() ?? 0
        let artistPeak = artist.values.max() ?? 0
        let genreNorm = genrePeak > 0 ? max(0, genreScore) / genrePeak : 0
        let artistNorm = artistPeak > 0 ? max(0, artistScore) / artistPeak : 0
        if artistNorm == 0 && genreNorm == 0 { return 0 }
        if artistNorm == 0 { return genreNorm * 0.55 }
        if genreNorm == 0 { return artistNorm * 0.85 }
        return min(1, 0.62 * artistNorm + 0.38 * genreNorm)
    }

    /// Stars are an explicit vote on top of play counts.
    static func ratingAmount(_ rating: Int) -> Double {
        switch rating {
        case 5: return 2.5
        case 4: return 1.2
        case 3: return 0.25
        case 2: return -1
        case 1: return -1.8
        default: return 0
        }
    }

    /// Repeats count, with diminishing return so one song can't own the profile.
    static func playAmount(_ plays: Int) -> Double {
        guard plays > 0 else { return 0 }
        return log2(1 + Double(plays))
    }

    private mutating func decay(to now: TimeInterval) {
        guard updatedAt > 0, now > updatedAt else {
            updatedAt = max(updatedAt, now)
            return
        }
        let factor = exp(-log(2) * (now - updatedAt) / Self.halfLife)
        if factor < 0.999 {
            for key in genre.keys { genre[key]! *= factor }
            for key in artist.keys { artist[key]! *= factor }
            mass *= factor
        }
        updatedAt = now
    }

    private mutating func prune() {
        genre = genre.filter { $0.value > 0.05 }
        artist = artist.filter { $0.value > 0.05 }
        if genre.count > 48 {
            let keep = genre.sorted { $0.value > $1.value }.prefix(48)
            genre = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        if artist.count > 200 {
            let keep = artist.sorted { $0.value > $1.value }.prefix(200)
            artist = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }
}
