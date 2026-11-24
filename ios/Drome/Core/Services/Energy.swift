import Foundation

/// Estimates perceived energy (0 = calm, 1 = high-energy) from genre and title.
///
/// Adapted from Aura’s `Energy` heuristic (GPL-3.0) — see NOTICE.
/// Subsonic exposes no BPM / acoustic features, so this is intentionally
/// simple and tunable; `VibeEngine` still applies vibe-specific gates on top.
enum Energy {
    /// Base energy per genre keyword (substring match, lowercased).
    private static let genreEnergy: [(keyword: String, value: Double)] = [
        // calm
        ("ambient", 0.10), ("classical", 0.15), ("acoustic", 0.20), ("folk", 0.25),
        ("singer-songwriter", 0.25), ("lo-fi", 0.20), ("lofi", 0.20), ("chill", 0.20),
        ("downtempo", 0.25), ("new age", 0.15), ("piano", 0.18), ("ballad", 0.20),
        ("jazz", 0.30), ("blues", 0.30), ("bossa", 0.25), ("soul", 0.35), ("gospel", 0.35),
        ("shoegaze", 0.35), ("slowcore", 0.20), ("r&b", 0.40), ("rnb", 0.40),
        // mid
        ("pop", 0.55), ("indie", 0.50), ("rock", 0.60), ("alternative", 0.55),
        ("country", 0.45), ("reggae", 0.45), ("funk", 0.60), ("disco", 0.65),
        ("soundtrack", 0.40), ("world", 0.45),
        // high
        ("edm", 0.85), ("house", 0.80), ("techno", 0.85), ("trance", 0.85),
        ("dance", 0.80), ("electro", 0.75), ("dubstep", 0.90), ("drum and bass", 0.90),
        ("dnb", 0.90), ("hip hop", 0.70), ("hip-hop", 0.70), ("rap", 0.70),
        ("trap", 0.75), ("hardstyle", 0.95), ("hardcore", 0.95), ("metal", 0.85),
        ("punk", 0.80), ("grime", 0.75), ("breakbeat", 0.80), ("garage", 0.75),
    ]

    private static let highEnergyTitleMarkers = [
        "remix", "club mix", "club edit", "extended", "vip mix",
        "bootleg", "rework", "(club", "mashup", "banger"
    ]
    private static let lowEnergyTitleMarkers = [
        "acoustic", "live", "unplugged", "instrumental", "stripped",
        "piano version", "slowed", "lullaby", "demo", "reprise",
        "adagio", "nocturne"
    ]

    /// Genre-only estimate (0…1).
    static func score(genre: String?) -> Double {
        guard let genre = genre?.lowercased(), !genre.isEmpty,
              let match = genreEnergy.first(where: { genre.contains($0.keyword) })
        else { return 0.5 }
        return match.value
    }

    static func score(_ song: Song) -> Double {
        var value = score(genre: song.genre)
        let title = song.title.lowercased()
        if highEnergyTitleMarkers.contains(where: { title.contains($0) }) { value += 0.20 }
        if lowEnergyTitleMarkers.contains(where: { title.contains($0) }) { value -= 0.25 }
        let seconds = song.duration ?? 0
        if seconds >= 420 { value -= 0.14 }
        else if seconds >= 300 { value -= 0.06 }
        else if seconds > 0 && seconds < 140 { value += 0.08 }
        return min(1.0, max(0.0, value))
    }
}
