import Foundation

/// Feeds Infinite Shuffle: when the queue is about to run dry, produces a
/// blend of (a) tracks similar to what's been playing, via Navidrome's
/// artist/genre metadata, and (b) broader weighted picks across the library
/// by rating and play count. Out-of-Rotation tracks never appear.
@MainActor
final class AutoplayProvider {
    private let client: SubsonicClient
    private let ratings: RatingsStore
    private let rotation: RotationManager
    private let database: AppDatabase
    private let userKey: String

    init(client: SubsonicClient, ratings: RatingsStore, rotation: RotationManager,
         database: AppDatabase, userKey: String) {
        self.client = client
        self.ratings = ratings
        self.rotation = rotation
        self.database = database
        self.userKey = userKey
    }

    func nextBatch(seeds: [Song], excluding: Set<String>, count: Int = 15, relaxed: Bool = false) async -> [Song] {
        let batch = await buildBatch(seeds: seeds, excluding: excluding, count: count, relaxed: relaxed)
        if !batch.isEmpty { return batch }
        guard !relaxed else { return await lastResortBatch(excluding: excluding, count: count) }
        return await nextBatch(seeds: seeds, excluding: excluding, count: count, relaxed: true)
    }

    private func buildBatch(
        seeds: [Song],
        excluding: Set<String>,
        count: Int,
        relaxed: Bool
    ) async -> [Song] {
        let excludedRotation = rotation.excludedIDs
        let recentPlays: Set<String> = relaxed ? [] : ((try? database.recentPlayIDs(
            userKey: userKey, withinHours: PlaybackPreferences.autoplayRecencyHours)) ?? [])
        let isAllowed: (Song) -> Bool = { song in
            !excluding.contains(song.id)
                && !excludedRotation.contains(song.id)
                && !recentPlays.contains(song.id)
                && !Self.isLowRatedExcluded(song, ratings: self.ratings)
        }

        // (a) Similar to recent listening: similar artists, then same genre.
        var similar: [Song] = []
        var seenArtists = Set<String>()
        let seedArtistIDs = seeds.reversed().compactMap(\.artistId).filter { seenArtists.insert($0).inserted }
        for artistID in seedArtistIDs.prefix(2) {
            similar += (try? await client.similarSongs(artistId: artistID, count: 25)) ?? []
        }
        if similar.count < 10, let genre = seeds.reversed().compactMap(\.genre).first {
            similar += (try? await client.songsByGenre(genre, count: 40)) ?? []
        }
        similar = similar.filter(isAllowed).uniquedByID()

        // (b) Broad weighted picks across the whole library.
        var broad = (try? await client.randomSongs(size: 120)) ?? []
        broad = broad.filter(isAllowed).uniquedByID()

        let taste = TasteAffinity.build(
            ratings: ratings.ratings,
            seeds: seeds,
            knownSongs: similar + broad)

        // Prefer this user's genres when taste is established — shared libraries
        // otherwise flood Infinite Shuffle with other people's music.
        if taste.isEstablished, !taste.preferredGenres.isEmpty, similar.count < count {
            for genre in taste.preferredGenres.prefix(3) {
                similar += (try? await client.songsByGenre(genre, count: 30)) ?? []
            }
            similar = similar.filter(isAllowed).uniquedByID()
        }

        let ratingOf: (Song) -> Int = { [weak self] song in
            self?.ratings.rating(for: song) ?? (song.userRating ?? 0)
        }

        // Weight broad picks by *this listener's* ratings. Unrated off-taste
        // tracks and global play counts are damped once taste is established.
        let broadRanked = broad
            .map { song -> (Song, Double) in
                let raw = ratingOf(song)
                let effective = taste.effectiveRating(for: song, raw: raw)
                let ratingWeight = pow(effective + 1, 2)
                let playWeight = taste.playCountFactor(for: song, rawRating: raw)
                let key = pow(Double.random(in: Double.ulpOfOne..<1), 1.0 / (ratingWeight * playWeight))
                return (song, key)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        let similarRanked = ShuffleEngine.weightedShuffle(similar, rating: ratingOf, taste: taste)

        // Blend similar/broad by station steering (Sonora-style).
        let (similarSlots, broadSlots) = Self.blendSlots(for: StationSteeringStore.current)
        var result: [Song] = []
        var similarIterator = similarRanked.makeIterator()
        var broadIterator = broadRanked.makeIterator()
        var pickedIDs = Set<String>()
        while result.count < count {
            var advanced = false
            for _ in 0..<similarSlots {
                if let s = similarIterator.next() {
                    advanced = true
                    if pickedIDs.insert(s.id).inserted { result.append(s) }
                }
            }
            for _ in 0..<broadSlots {
                if let b = broadIterator.next() {
                    advanced = true
                    if pickedIDs.insert(b.id).inserted { result.append(b) }
                }
            }
            if !advanced { break }
        }

        // Keep This Vibe: prefer seed genre / artist affinity after the blend.
        if StationSteeringStore.current == .keepVibe {
            let seedGenres = Set(seeds.compactMap { song -> String? in
                guard let g = song.genre else { return nil }
                return GenreNormalizer.shared.normalize(g) ?? g
            })
            let seedArtists = Set(seeds.compactMap(\.artistId))
            result.sort { a, b in
                let ascore = Self.vibeAffinity(a, genres: seedGenres, artists: seedArtists)
                let bscore = Self.vibeAffinity(b, genres: seedGenres, artists: seedArtists)
                return ascore > bscore
            }
        }

        // More Familiar: prefer higher ratings / play counts.
        if StationSteeringStore.current == .familiar {
            result.sort { a, b in
                ratingOf(a) > ratingOf(b)
            }
        }

        // More Discovery: prefer low play count / unrated.
        if StationSteeringStore.current == .discovery {
            result.sort { a, b in
                let ap = a.playCount ?? 0
                let bp = b.playCount ?? 0
                if ap != bp { return ap < bp }
                return ratingOf(a) < ratingOf(b)
            }
        }

        return Array(result.prefix(count))
    }

    private static func blendSlots(for steering: StationSteering) -> (similar: Int, broad: Int) {
        switch steering {
        case .balanced: return (3, 2)
        case .familiar: return (4, 1)
        case .discovery: return (1, 4)
        case .keepVibe: return (5, 1)
        }
    }

    private static func vibeAffinity(_ song: Song, genres: Set<String>, artists: Set<String>) -> Int {
        var score = 0
        if let g = song.genre {
            let normalized = GenreNormalizer.shared.normalize(g) ?? g
            if genres.contains(normalized) { score += 3 }
        }
        if let a = song.artistId, artists.contains(a) { score += 2 }
        return score
    }

    /// When metadata filters empty the pool, still keep Infinite Shuffle going.
    private func lastResortBatch(excluding: Set<String>, count: Int) async -> [Song] {
        let excludedRotation = rotation.excludedIDs
        let pool = ((try? await client.randomSongs(size: 120)) ?? [])
            .filter { song in
                !excluding.contains(song.id)
                    && !excludedRotation.contains(song.id)
                    && !Self.isLowRatedExcluded(song, ratings: ratings)
            }
            .uniquedByID()
        return Array(pool.shuffled().prefix(count))
    }

    /// Low-rated tracks are always kept out of Infinite Shuffle pools.
    private static func isLowRatedExcluded(_ song: Song, ratings: RatingsStore) -> Bool {
        let r = ratings.rating(for: song)
        return (1...2).contains(r)
    }
}
