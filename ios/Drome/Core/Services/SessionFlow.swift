import Foundation

/// One candidate for a smooth listening sequence.
///
/// Playlists people actually build keep neighboring tracks closer in genre
/// and energy than a random pair from the same list, and that closeness
/// fades after a few songs (ISMIR 2021, "Does Track Sequence Matter?").
/// Artist and album repeats are the thing listeners notice immediately, so
/// those stay spaced even when the songs are a great taste match.
struct FlowTrack: Hashable, Sendable {
    var id: String
    var artist: String
    var album: String
    var genre: String
    /// 0 = still, 1 = full send. Estimated when the library has no BPM.
    var energy: Double
    var year: Int
    /// Taste weight. Higher songs are more likely, but a cliff in mood loses.
    var weight: Double
}

/// Orders an already-chosen pool so the mood walks instead of teleporting.
///
/// Selection (what belongs) stays with the caller. This only re-ranks, which
/// is the split used by coherent playlist generators: pick a relevant set,
/// then choose the next track from the ones that sit next to what's playing.
enum SessionFlow {
    /// Same artist stays out of the next few slots when the pool allows it.
    static let artistGap = 3
    static let albumGap = 2

    static func arrange(
        _ tracks: [FlowTrack],
        anchor: FlowTrack? = nil,
        strictGenre: Bool = true,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> [FlowTrack] {
        var pool = tracks
        var placed: [FlowTrack] = []
        placed.reserveCapacity(pool.count)
        var previous = anchor
        while !pool.isEmpty {
            // The song already playing counts toward the artist gap, so the
            // next one isn't the same person again.
            var history = placed
            if history.isEmpty, let anchor {
                history = [anchor]
            }
            guard let next = pick(
                from: &pool,
                previous: previous,
                recent: history,
                strictGenre: strictGenre,
                random: random)
            else { break }
            placed.append(next)
            previous = next
        }
        return placed
    }

    /// 1 same genre, ~0.8 a neighbor, low when the room would actually change.
    static func genreFit(_ a: String, _ b: String, strict: Bool) -> Double {
        if a.isEmpty || b.isEmpty || a == b { return 1 }
        if neighbors[a]?.contains(b) == true || neighbors[b]?.contains(a) == true {
            return 0.78
        }
        return strict ? 0.22 : 0.62
    }

    // MARK: - Private

    private static func pick(
        from pool: inout [FlowTrack],
        previous: FlowTrack?,
        recent: [FlowTrack],
        strictGenre: Bool,
        random: () -> Double
    ) -> FlowTrack? {
        let artists = recent.map(\.artist)
        let albums = recent.map(\.album)
        for gap in [artistGap, 2, 1, 0] {
            var scored: [(Int, Double)] = []
            scored.reserveCapacity(pool.count)
            for (index, track) in pool.enumerated() {
                let score = fit(
                    track,
                    previous: previous,
                    recentArtists: artists,
                    recentAlbums: albums,
                    artistGap: gap,
                    strictGenre: strictGenre)
                if score >= 0 {
                    scored.append((index, score))
                }
            }
            guard !scored.isEmpty else { continue }
            scored.sort { $0.1 > $1.1 }
            let best = scored[0].1
            let beam = scored.filter { $0.1 >= best * 0.72 }
            let chosen = weightedIndex(beam, random: random)
            return pool.remove(at: chosen)
        }
        return pool.isEmpty ? nil : pool.removeFirst()
    }

    private static func fit(
        _ track: FlowTrack,
        previous: FlowTrack?,
        recentArtists: [String],
        recentAlbums: [String],
        artistGap: Int,
        strictGenre: Bool
    ) -> Double {
        if artistGap > 0, !track.artist.isEmpty,
           recentArtists.suffix(artistGap).contains(track.artist) {
            return -1
        }
        if artistGap > 0, !track.album.isEmpty,
           recentAlbums.suffix(albumGap).contains(track.album) {
            return -1
        }
        var continuity = 1.0
        if let previous {
            let jump = abs(track.energy - previous.energy)
            continuity *= max(0.08, 1 - jump * 1.7)
            continuity *= genreFit(track.genre, previous.genre, strict: strictGenre)
            if track.year > 0, previous.year > 0 {
                let gap = abs(track.year - previous.year)
                if gap > 20 { continuity *= 0.84 }
                if gap > 40 { continuity *= 0.78 }
            }
        }
        let weight = max(0.15, track.weight)
        return pow(weight, 0.62) * continuity
    }

    private static func weightedIndex(_ beam: [(Int, Double)], random: () -> Double) -> Int {
        let total = beam.reduce(0.0) { $0 + max(0.01, $1.1) }
        var ticket = min(max(0, random()), 0.999999) * total
        for item in beam {
            ticket -= max(0.01, item.1)
            if ticket <= 0 { return item.0 }
        }
        return beam[0].0
    }

    /// Genres that commonly sit next to each other in a radio without a
    /// listener hearing the station change. Energy still has to agree.
    private static let neighbors: [String: Set<String>] = [
        "Jazz": ["Blues", "Soul", "Ambient", "Soundtrack"],
        "Blues": ["Jazz", "Soul", "Rock", "Folk"],
        "Soul": ["Jazz", "R&B", "Funk", "Blues", "Pop"],
        "R&B": ["Soul", "Hip-Hop", "Pop", "Funk"],
        "Funk": ["Soul", "R&B", "Pop", "Disco"],
        "Hip-Hop": ["R&B", "Dance", "Electronic"],
        "Pop": ["Funk", "Soul", "Dance", "Indie", "R&B", "Reggae"],
        "Dance": ["Pop", "Electronic", "Hip-Hop", "Funk"],
        "Electronic": ["Dance", "Ambient", "Hip-Hop", "Experimental"],
        "Ambient": ["Electronic", "Jazz", "Classical", "Soundtrack"],
        "Classical": ["Ambient", "Soundtrack"],
        "Soundtrack": ["Classical", "Ambient", "Jazz"],
        "Folk": ["Country", "Indie", "Blues", "Alternative"],
        "Country": ["Folk", "Rock", "Blues"],
        "Indie": ["Folk", "Alternative", "Pop", "Rock"],
        "Alternative": ["Indie", "Rock", "Punk", "Folk"],
        "Rock": ["Alternative", "Punk", "Country", "Blues", "Metal"],
        "Punk": ["Rock", "Alternative", "Metal"],
        "Metal": ["Rock", "Punk"],
        "Reggae": ["Soul", "Pop", "Folk"],
        "Experimental": ["Electronic", "Ambient", "Rock"],
    ]
}
