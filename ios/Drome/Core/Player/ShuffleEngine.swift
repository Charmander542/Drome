import Foundation

enum ShuffleEngine {
    /// Whether playback should stay inside an Out of Rotation collection
    /// (system OOR playlist, or a playlist that is entirely OOR) instead of
    /// falling through to library Infinite Shuffle / low-rated skip.
    static func sticksToOutOfRotationPool(
        allowsOutOfRotation: Bool,
        contextSongIDs: [String],
        excludedIDs: Set<String>
    ) -> Bool {
        if allowsOutOfRotation { return true }
        guard !contextSongIDs.isEmpty, !excludedIDs.isEmpty else { return false }
        return contextSongIDs.allSatisfy { excludedIDs.contains($0) }
    }

    /// Weighted shuffle (sampling without replacement) favoring higher-rated
    /// tracks: weight ∝ (effectiveRating + 1)². Unrated tracks are neutral 3★
    /// until `TasteAffinity` is established, then off-taste unrated songs drop
    /// so multi-user libraries don't dominate. Efraimidis–Spirakis keys.
    static func weightedShuffle(
        _ songs: [Song],
        rating: (Song) -> Int,
        taste: TasteAffinity = .empty
    ) -> [Song] {
        songs
            .map { song -> (Song, Double) in
                let raw = rating(song)
                let effective = taste.effectiveRating(for: song, raw: raw)
                let weight = pow(effective + 1, 2)
                let key = pow(Double.random(in: Double.ulpOfOne..<1), 1.0 / weight)
                return (song, key)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Order the given songs for playback under a shuffle mode, dropping
    /// anything that is out of rotation (unless allowed by context).
    ///
    /// If every track is excluded (e.g. Shuffle on a playlist that is entirely
    /// Out of Rotation), fall back to shuffling the full list so the button
    /// still does what the user asked.
    static func order(_ songs: [Song], mode: ShuffleMode,
                      rating: (Song) -> Int,
                      excluded: Set<String>,
                      taste: TasteAffinity = .empty) -> [Song] {
        switch mode {
        case .off:
            return songs
        case .random, .smart:
            let eligible = songs.filter { !excluded.contains($0.id) }
            let pool = eligible.isEmpty ? songs : eligible
            switch mode {
            case .random:
                return pool.shuffled()
            case .smart:
                return weightedShuffle(pool, rating: rating, taste: taste)
            case .off:
                return songs
            }
        }
    }
}
