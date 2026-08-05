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

    func nextBatch(seeds: [Song], excluding: Set<String>, count: Int = 15) async -> [Song] {
        let excludedRotation = rotation.excludedIDs
        let recentPlays = (try? database.recentPlayIDs(
            userKey: userKey, withinHours: PlaybackPreferences.autoplayRecencyHours)) ?? []
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

        let ratingOf: (Song) -> Int = { [weak self] song in
            self?.ratings.rating(for: song) ?? (song.userRating ?? 0)
        }

        // Weight broad picks by rating and (lightly) play count.
        let broadRanked = broad
            .map { song -> (Song, Double) in
                let raw = ratingOf(song)
                let effective = raw == 0 ? 3 : raw
                let ratingWeight = pow(Double(effective + 1), 2)
                let playWeight = log2(2.0 + Double(song.playCount ?? 0))
                let key = pow(Double.random(in: Double.ulpOfOne..<1), 1.0 / (ratingWeight * playWeight))
                return (song, key)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)

        let similarRanked = ShuffleEngine.weightedShuffle(similar, rating: ratingOf)

        // Blend roughly 60/40 similar/broad, interleaved, deduped.
        var result: [Song] = []
        var similarIterator = similarRanked.makeIterator()
        var broadIterator = broadRanked.makeIterator()
        var pickedIDs = Set<String>()
        while result.count < count {
            var advanced = false
            for _ in 0..<3 {
                if let s = similarIterator.next() {
                    advanced = true
                    if pickedIDs.insert(s.id).inserted { result.append(s) }
                }
            }
            for _ in 0..<2 {
                if let b = broadIterator.next() {
                    advanced = true
                    if pickedIDs.insert(b.id).inserted { result.append(b) }
                }
            }
            if !advanced { break }
        }
        return Array(result.prefix(count))
    }

    /// Low-rated tracks are always kept out of Infinite Shuffle pools.
    private static func isLowRatedExcluded(_ song: Song, ratings: RatingsStore) -> Bool {
        let r = ratings.rating(for: song)
        return (1...2).contains(r)
    }
}
