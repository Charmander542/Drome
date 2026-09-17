import Foundation

/// Builds a vibe queue entirely on-device from Navidrome genre pulls.
/// Scores tempo / vocal character / genre — never ratings or play-count.
enum VibeEngine {
    static let mixLength = 40

    struct Taste {
        /// Normalized GenreNormalizer names this vibe wants.
        var prefer: Set<String>
        var avoid: Set<String>
        /// Genre strings to ask Navidrome for (libraries tag wildly).
        var fetch: [String]
        /// 0 = lullaby, 1 = full send.
        var energy: ClosedRange<Double>
        var vocals: Vocals
        var titleBoost: [String]
        var titleAvoid: [String]
        /// Prefer longer (classical / ambient) or shorter (hype) tracks.
        var durationBias: DurationBias
    }

    enum Vocals {
        /// Classical / scores — spoken lyrics fight focus.
        case instrumental
        /// Country, heartbreak, late night — words are the point.
        case lyrical
        case either
    }

    enum DurationBias {
        case longer
        case shorter
        case none
    }

    static func taste(for vibe: MoodVibe) -> Taste {
        switch vibe {
        case .focus:
            return Taste(
                prefer: ["Jazz", "Classical", "Ambient", "Soundtrack", "Blues"],
                avoid: ["Hip-Hop", "Dance", "Pop", "Metal", "Punk", "Country", "Rock",
                        "Electronic", "Indie", "Alternative"],
                fetch: ["Jazz", "Cool Jazz", "Smooth Jazz", "Bebop", "Instrumental",
                        "Classical", "Soundtrack", "Ambient", "Piano", "Score",
                        "Minimal", "Modern Classical", "New Age", "Blues"],
                // Jazz lands ~0.34; keep room for slow instrumentals without
                // pulling in mid-tempo vocal pop.
                energy: 0.0...0.40,
                vocals: .instrumental,
                titleBoost: ["piano", "sonata", "concerto", "nocturne", "prelude",
                             "adagio", "andante", "symphony", "quartet", "trio",
                             "quintet", "suite", "etude", "étude", "op.", "movement",
                             "score", "theme", "ambient", "meditation", "instrumental",
                             "solo", "sax", "trumpet", "improvis"],
                titleAvoid: ["remix", "radio edit", "feat", "ft.", "rap", "vocal",
                             "sings", "lyrics"],
                durationBias: .longer)
        case .lateNight:
            return Taste(
                prefer: ["Jazz", "Soul", "R&B", "Blues", "Folk", "Ambient"],
                avoid: ["Dance", "Metal", "Punk", "Hip-Hop"],
                fetch: ["Jazz", "Soul", "R&B", "RnB", "Neo-Soul", "Blues",
                        "Singer/Songwriter", "Singer-Songwriter", "Quiet Storm"],
                energy: 0.08...0.42,
                vocals: .lyrical,
                titleBoost: ["night", "midnight", "moon", "sleep", "dream", "quiet",
                             "stars", "lullaby", "slow", "rain", "blue", "late"],
                titleAvoid: ["party", "club", "banger", "remix", "workout"],
                durationBias: .none)
        case .chill:
            return Taste(
                prefer: ["Country", "Folk", "Indie"],
                avoid: ["Dance", "Electronic", "Metal", "Hip-Hop", "Classical", "Punk"],
                fetch: ["Country", "Americana", "Folk", "Alt-Country", "Alt Country",
                        "Singer/Songwriter", "Singer-Songwriter", "Bluegrass", "Acoustic"],
                energy: 0.18...0.48,
                vocals: .lyrical,
                titleBoost: ["highway", "whiskey", "truck", "cowboy", "porch",
                             "acoustic", "river", "dirt", "town", "road"],
                titleAvoid: ["remix", "club", "edm"],
                durationBias: .none)
        case .heartbreak:
            return Taste(
                prefer: ["Indie", "Folk", "Alternative", "R&B", "Soul", "Pop"],
                avoid: ["Dance", "Metal", "Punk", "Hip-Hop"],
                fetch: ["Indie", "Folk", "Singer/Songwriter", "Singer-Songwriter",
                        "Alternative", "Sadcore", "Ballad", "R&B", "Soul"],
                energy: 0.12...0.48,
                vocals: .lyrical,
                titleBoost: ["heart", "cry", "gone", "miss", "lonely", "goodbye",
                             "leave", "rain", "sad", "tear", "broke", "hurt",
                             "empty", "without", "sorry", "over"],
                titleAvoid: ["party", "club", "banger", "workout"],
                durationBias: .none)
        case .feelGood:
            return Taste(
                prefer: ["Pop", "Funk", "Soul", "Reggae", "Indie", "Dance"],
                avoid: ["Metal", "Classical", "Ambient", "Punk"],
                fetch: ["Pop", "Funk", "Disco", "Reggae", "Indie Pop", "Soul",
                        "Motown", "Ska"],
                energy: 0.48...0.82,
                vocals: .either,
                titleBoost: ["happy", "sun", "summer", "love", "good", "dance",
                             "smile", "fun", "together", "alive", "light"],
                titleAvoid: ["cry", "lonely", "funeral", "dead"],
                durationBias: .none)
        case .hype:
            return Taste(
                prefer: ["Hip-Hop", "Dance", "Electronic", "Rock", "Punk", "Metal"],
                avoid: ["Classical", "Ambient", "Soundtrack", "Folk", "Country", "Jazz"],
                fetch: ["Hip-Hop", "Hip Hop", "Rap", "Trap", "EDM", "Dance",
                        "Electronic", "Rock", "Punk", "Metal"],
                energy: 0.62...1.0,
                vocals: .either,
                titleBoost: ["fire", "run", "go", "up", "power", "wild", "loud"],
                titleAvoid: ["lullaby", "nocturne", "adagio", "sleep"],
                durationBias: .shorter)
        case .lucky:
            return Taste(
                prefer: [],
                avoid: [],
                fetch: [],
                energy: 0...1,
                vocals: .either,
                titleBoost: [],
                titleAvoid: [],
                durationBias: .none)
        }
    }

    static func pick(vibe: MoodVibe, from songs: [Song], excluded: Set<String>) -> [Song] {
        let pool = songs.filter { !excluded.contains($0.id) }.uniquedByID()
        guard !pool.isEmpty else { return [] }
        if vibe == .lucky {
            return Array(pool.shuffled().prefix(mixLength))
        }
        let spec = taste(for: vibe)
        let eligible = pool.filter { passesHardGate($0, spec: spec) }
        let candidatePool = eligible.isEmpty ? pool : eligible
        var scored = candidatePool.compactMap { song -> (Song, Double)? in
            let s = score(song, spec: spec)
            return s > 0.35 ? (song, s) : nil
        }
        if scored.count < 12, vibe != .focus {
            // Relax: keep anything that isn't in the avoid set.
            scored = candidatePool.compactMap { song -> (Song, Double)? in
                let g = normalizedGenre(song)
                if let g, spec.avoid.contains(g) { return nil }
                return (song, max(0.2, score(song, spec: spec)))
            }
        }
        // Weighted random sample — not "always the same top band shuffled".
        // Each Play draws a new queue from the fit pool.
        return weightedSample(scored, count: mixLength)
    }

    /// Hard filters so relax paths can't pull hype/pop/electronic into Focus.
    private static func passesHardGate(_ song: Song, spec: Taste) -> Bool {
        let genre = normalizedGenre(song)
        if let genre, spec.avoid.contains(genre) { return false }

        let energy = estimatedEnergy(song, genre: genre)
        if energy > spec.energy.upperBound + 0.06 { return false }

        if spec.vocals == .instrumental {
            let hay = haystack(song)
            if !looksInstrumental(hay, genre: genre) {
                return false
            }
        }
        return true
    }

    /// Sample `count` songs without replacement, weighted by fit score.
    private static func weightedSample(_ scored: [(Song, Double)], count: Int) -> [Song] {
        guard !scored.isEmpty else { return [] }
        var pool = scored
        var out: [Song] = []
        out.reserveCapacity(min(count, pool.count))
        while out.count < count, !pool.isEmpty {
            let total = pool.reduce(0.0) { $0 + max(0.05, $1.1) }
            var ticket = Double.random(in: 0..<total)
            var pick = 0
            for (i, item) in pool.enumerated() {
                ticket -= max(0.05, item.1)
                if ticket <= 0 {
                    pick = i
                    break
                }
            }
            out.append(pool.remove(at: pick).0)
        }
        return out
    }

    static func score(_ song: Song, spec: Taste) -> Double {
        let genre = normalizedGenre(song)
        let hay = haystack(song)

        var score = 0.45

        if let genre {
            if spec.prefer.contains(genre) { score += 0.38 }
            if spec.avoid.contains(genre) { score -= 0.55 }
        } else {
            score -= 0.08
        }

        let energy = estimatedEnergy(song, genre: genre)
        if spec.energy.contains(energy) {
            score += 0.28
        } else {
            let mid = (spec.energy.lowerBound + spec.energy.upperBound) / 2
            let dist = abs(energy - mid)
            score -= min(0.4, dist * 0.7)
        }

        switch spec.vocals {
        case .instrumental:
            if looksInstrumental(hay, genre: genre) { score += 0.22 }
            else { score -= 0.18 }
        case .lyrical:
            if looksInstrumental(hay, genre: genre) { score -= 0.16 }
            else { score += 0.14 }
        case .either:
            break
        }

        if spec.titleBoost.contains(where: { hay.contains($0) }) { score += 0.2 }
        if spec.titleAvoid.contains(where: { hay.contains($0) }) { score -= 0.28 }

        let seconds = song.duration ?? 0
        switch spec.durationBias {
        case .longer:
            if seconds >= 240 { score += 0.1 }
            if seconds >= 360 { score += 0.08 }
            if seconds > 0 && seconds < 150 { score -= 0.12 }
        case .shorter:
            if seconds > 0 && seconds <= 210 { score += 0.08 }
            if seconds >= 360 { score -= 0.12 }
        case .none:
            break
        }

        return score
    }

    static func normalizedGenre(_ song: Song) -> String? {
        guard let raw = song.genre, !raw.isEmpty else { return nil }
        return GenreNormalizer.shared.normalize(raw)
    }

    /// Crude energy 0...1 from genre + duration when the library has no BPM.
    static func estimatedEnergy(_ song: Song, genre: String?) -> Double {
        var e: Double
        switch genre {
        case "Classical", "Ambient": e = 0.16
        case "Soundtrack": e = 0.28
        // Slow/cool jazz fits focus; keep below mid-tempo defaults.
        case "Jazz": e = 0.28
        case "Blues": e = 0.32
        case "Folk", "Country": e = 0.36
        case "Soul", "R&B": e = 0.42
        case "Indie", "Alternative": e = 0.48
        case "Pop", "Funk", "Reggae": e = 0.62
        case "Rock": e = 0.7
        case "Hip-Hop", "Electronic": e = 0.78
        case "Dance": e = 0.86
        case "Punk", "Metal": e = 0.92
        default: e = 0.5
        }
        let seconds = song.duration ?? 0
        if seconds >= 420 { e -= 0.14 }
        else if seconds >= 300 { e -= 0.06 }
        else if seconds > 0 && seconds < 140 { e += 0.08 }
        let hay = haystack(song)
        if hay.contains("adagio") || hay.contains("nocturne") || hay.contains("lullaby") { e -= 0.2 }
        if hay.contains("remix") || hay.contains("club") || hay.contains("banger") { e += 0.15 }
        return min(1, max(0, e))
    }

    private static func looksInstrumental(_ hay: String, genre: String?) -> Bool {
        if genre == "Classical" || genre == "Ambient" || genre == "Soundtrack" {
            return true
        }
        // Jazz/Blues are often instrumental; treat as such unless clearly vocal.
        if genre == "Jazz" || genre == "Blues" {
            let vocalMarks = ["vocal", "vocals", "sings", "feat", "ft.", "lyrics"]
            if vocalMarks.contains(where: { hay.contains($0) }) { return false }
            return true
        }
        let marks = ["instrumental", "piano", "sonata", "concerto", "symphony",
                     "quartet", "trio", "quintet", "nocturne", "etude", "étude",
                     "op.", "score", "solo piano"]
        return marks.contains(where: { hay.contains($0) })
    }

    private static func haystack(_ song: Song) -> String {
        [song.title, song.album, song.artist, song.genre]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }
}
