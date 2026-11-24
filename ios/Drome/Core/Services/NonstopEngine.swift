import Foundation

/// Endless station algorithm: liked → near → unheard, in turn.
///
/// Adapted from Aura’s Nonstop refill in `AudioPlayer` (GPL-3.0) — see NOTICE.
/// Session skip/dislike bans are local to one Nonstop run; a new start clears them.
enum NonstopEngine {
    static let label = "Nonstop"
    static let earlySkipSeconds: TimeInterval = 30
    static let batchSize = 30
    static let openingCount = 4

    /// Per-run memory: early skips and “not for me” choices.
    struct Session: Sendable {
        var earlySkipsByArtist: [String: Int] = [:]
        var dislikedSongIDs: Set<String> = []
        var dislikedArtists: [String: Int] = [:]

        var bannedArtists: Set<String> {
            var banned = Set(dislikedArtists.filter { $0.value >= 2 }.keys)
            banned.formUnion(earlySkipsByArtist.filter { $0.value >= 2 }.keys)
            return banned
        }

        mutating func reset() {
            earlySkipsByArtist = [:]
            dislikedSongIDs = []
            dislikedArtists = [:]
        }

        /// Skip in the first half-minute: two early skips ban the artist for this run.
        mutating func recordEarlySkip(artist: String?) {
            guard let artist, !artist.isEmpty else { return }
            earlySkipsByArtist[artist, default: 0] += 1
        }

        /// “Not for me”: song out for the run; artist twice → ban upcoming too.
        mutating func dislike(song: Song) -> Set<String> {
            dislikedSongIDs.insert(song.id)
            let artist = song.artistId ?? song.artist ?? ""
            guard !artist.isEmpty else { return [] }
            dislikedArtists[artist, default: 0] += 1
            if dislikedArtists[artist, default: 0] >= 2 {
                return [artist]
            }
            return []
        }
    }

    /// A few liked (or seed) songs by different artists so Nonstop opens instantly.
    static func opening(from seeds: [Song], excludedGenres: Set<String>) -> [Song] {
        var opening: [Song] = []
        var artists = Set<String>()
        for song in seeds.shuffled() where opening.count < openingCount {
            guard allowsGenre(song, excluded: excludedGenres) else { continue }
            let artist = song.artistId ?? song.artist ?? song.id
            guard artists.insert(artist).inserted else { continue }
            opening.append(song)
        }
        if opening.isEmpty {
            opening = Array(seeds.prefix(openingCount))
        }
        return opening
    }

    /// Four liked, four near, two unheard — round-robin; ≤2 songs per artist.
    static func batch(
        liked: [Song],
        near: [Song],
        random: [Song],
        played: Set<String>,
        session: Session,
        excludedGenres: Set<String>,
        rotationExcluded: Set<String>,
        count: Int = batchSize
    ) -> [Song] {
        var taken = played
            .union(session.dislikedSongIDs)
            .union(rotationExcluded)
        let banned = session.bannedArtists
        var perArtist: [String: Int] = [:]

        func fits(_ song: Song) -> Bool {
            let artist = song.artistId ?? song.artist ?? ""
            guard !taken.contains(song.id),
                  !banned.contains(artist),
                  perArtist[artist, default: 0] < 2,
                  allowsGenre(song, excluded: excludedGenres)
            else { return false }
            taken.insert(song.id)
            if !artist.isEmpty { perArtist[artist, default: 0] += 1 }
            return true
        }

        var pools = [liked.shuffled(), near.shuffled(), random.shuffled()].map { $0.makeIterator() }
        // Aura pattern: liked, near, liked, near, random, …
        let pattern = [0, 1, 0, 1, 2, 0, 1, 0, 1, 2]
        var batch: [Song] = []
        var dry = 0
        while batch.count < count, dry < pattern.count {
            dry = 0
            for slot in pattern where batch.count < count {
                var found: Song?
                for offset in 0..<3 {
                    while let song = pools[(slot + offset) % 3].next() {
                        if fits(song) { found = song; break }
                    }
                    if found != nil { break }
                }
                if let found { batch.append(found) } else { dry += 1 }
            }
        }
        return batch
    }

    private static func allowsGenre(_ song: Song, excluded: Set<String>) -> Bool {
        guard !excluded.isEmpty else { return true }
        let raw = (song.genre ?? "").lowercased()
        guard !raw.isEmpty else { return true }
        if excluded.contains(raw) { return false }
        if let normalized = GenreNormalizer.shared.normalize(song.genre ?? ""),
           excluded.contains(normalized.lowercased()) {
            return false
        }
        let parts = raw.split(whereSeparator: { ";,/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return !parts.contains(where: excluded.contains)
    }
}
