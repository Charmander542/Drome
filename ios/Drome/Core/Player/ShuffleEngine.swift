import Foundation

enum ShuffleEngine {
    /// Taste-weighted order, then a smooth walk so the next song stays in the
/// same room as the one before it.
    ///
    /// Keys are Efraimidis–Spirakis (weight ∝ (effectiveRating + 1)²) so a
    /// loved song is likely but not guaranteed. Unrated tracks are neutral 3★
    /// until taste is established, then off-taste unrated songs drop so a
    /// shared library doesn't take over. The walk only reorders the front of
    /// a long list — the tail stays in weighted order.
    static func weightedShuffle(
        _ songs: [Song],
        rating: (Song) -> Int,
        taste: TasteAffinity = .empty
    ) -> [Song] {
        let ranked = songs
            .map { song -> (Song, Double) in
                let raw = rating(song)
                let effective = taste.effectiveRating(for: song, raw: raw)
                let weight = pow(effective + 1, 2)
                let key = pow(Double.random(in: Double.ulpOfOne..<1), 1.0 / weight)
                return (song, key)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        let headCount = min(ranked.count, 240)
        let head = sequence(Array(ranked.prefix(headCount)), rating: rating, taste: taste)
        if headCount == ranked.count { return head }
        return head + ranked.dropFirst(headCount)
    }

    /// Re-rank so neighbors share genre and energy, and the same artist waits.
    private static func sequence(
        _ songs: [Song],
        rating: (Song) -> Int,
        taste: TasteAffinity
    ) -> [Song] {
        let tracks: [FlowTrack] = songs.map { song in
            let genre = GenreNormalizer.shared.normalize(song.genre ?? "") ?? ""
            return FlowTrack(
                id: song.id,
                artist: song.artistId ?? song.artist ?? "",
                album: song.albumId ?? "",
                genre: genre,
                energy: VibeEngine.estimatedEnergy(song, genre: genre.isEmpty ? nil : genre),
                year: song.year ?? 0,
                weight: taste.effectiveRating(for: song, raw: rating(song)))
        }
        let ordered = SessionFlow.arrange(tracks)
        var byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return ordered.compactMap { byID.removeValue(forKey: $0.id) }
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
