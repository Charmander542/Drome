import Foundation

enum ShuffleEngine {
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
    static func order(_ songs: [Song], mode: ShuffleMode,
                      rating: (Song) -> Int,
                      excluded: Set<String>,
                      taste: TasteAffinity = .empty) -> [Song] {
        switch mode {
        case .off:
            return songs
        case .random:
            return songs.filter { !excluded.contains($0.id) }.shuffled()
        case .smart:
            return weightedShuffle(
                songs.filter { !excluded.contains($0.id) },
                rating: rating,
                taste: taste)
        }
    }
}
