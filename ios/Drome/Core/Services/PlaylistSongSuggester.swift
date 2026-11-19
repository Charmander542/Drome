import Foundation

/// Suggests tracks that fit a playlist’s existing vibe — top artists / genres
/// from the list, plus similar-artist pulls. Purely on-device over Subsonic.
@MainActor
enum PlaylistSongSuggester {
    struct Suggestion: Identifiable, Hashable {
        let song: Song
        /// Short reason shown under the title (“More rock · like Arctic Monkeys”).
        let reason: String
        var id: String { song.id }
    }

    private struct Profile {
        var topGenres: [(name: String, count: Int)]
        var topArtistIDs: [(id: String, name: String, count: Int)]
        var dominantGenre: String?
    }

    static func suggest(
        for playlistSongs: [Song],
        client: SubsonicClient,
        excluding excludedIDs: Set<String>,
        limit: Int = 12
    ) async -> [Suggestion] {
        guard playlistSongs.count >= 2 else { return [] }

        let profile = buildProfile(from: playlistSongs)
        var pool: [Song] = []
        var reasons: [String: String] = [:]

        // Similar artists first — strongest “same vibe” signal.
        for artist in profile.topArtistIDs.prefix(4) {
            let similar = (try? await client.similarSongs(artistId: artist.id, count: 20)) ?? []
            for song in similar {
                if reasons[song.id] == nil {
                    reasons[song.id] = "Like \(artist.name)"
                }
            }
            pool += similar
        }

        // Genre fills keep the theme consistent when similar-artists is thin.
        for genre in profile.topGenres.prefix(3) {
            let batch = (try? await client.songsByGenre(genre.name, count: 35)) ?? []
            for song in batch {
                if reasons[song.id] == nil {
                    reasons[song.id] = "More \(genre.name)"
                }
            }
            pool += batch
        }

        let inPlaylist = Set(playlistSongs.map(\.id)).union(excludedIDs)
        let candidates = pool
            .filter { !inPlaylist.contains($0.id) }
            .uniquedByID()

        guard !candidates.isEmpty else { return [] }

        let ranked = rank(candidates, profile: profile, playlistSongs: playlistSongs)
        return ranked.prefix(limit).map { song in
            Suggestion(
                song: song,
                reason: reasons[song.id] ?? reasonFallback(for: song, profile: profile))
        }
    }

    // MARK: - Profile

    private static func buildProfile(from songs: [Song]) -> Profile {
        var genreCounts: [String: Int] = [:]
        var artistCounts: [String: (name: String, count: Int)] = [:]

        for song in songs {
            if let raw = song.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty {
                // Keep the library’s own spelling for Subsonic genre queries.
                genreCounts[raw, default: 0] += 1
            }
            if let id = song.artistId, !id.isEmpty {
                let name = song.displayArtist.isEmpty ? "Artist" : song.displayArtist
                let prior = artistCounts[id]?.count ?? 0
                artistCounts[id] = (name: name, count: prior + 1)
            }
        }

        let topGenres = genreCounts
            .map { (name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        let topArtists = artistCounts
            .map { (id: $0.key, name: $0.value.name, count: $0.value.count) }
            .sorted { $0.count > $1.count }

        return Profile(
            topGenres: topGenres,
            topArtistIDs: topArtists,
            dominantGenre: topGenres.first?.name)
    }

    // MARK: - Ranking

    private static func rank(
        _ songs: [Song],
        profile: Profile,
        playlistSongs: [Song]
    ) -> [Song] {
        let genreSet = Set(profile.topGenres.prefix(5).map { $0.name.lowercased() })
        let artistSet = Set(profile.topArtistIDs.prefix(8).map(\.id))
        let playlistArtistNames = Set(
            playlistSongs.compactMap { $0.artist?.lowercased() }.filter { !$0.isEmpty })

        // Soft duration band so we don't suggest 20‑min jams into a 3‑min pop list.
        let durations = playlistSongs.compactMap { $0.duration }.filter { $0 > 0 }
        let medianDuration: Int? = {
            guard !durations.isEmpty else { return nil }
            let sorted = durations.sorted()
            return sorted[sorted.count / 2]
        }()

        return songs
            .map { song -> (Song, Double) in
                var score = 1.0
                if let id = song.artistId, artistSet.contains(id) {
                    score += 4.5
                } else if let artist = song.artist?.lowercased(),
                          playlistArtistNames.contains(artist) {
                    score += 3.0
                }
                if let genre = song.genre?.lowercased(), genreSet.contains(genre) {
                    score += 3.5
                }
                if let med = medianDuration, let dur = song.duration, dur > 0 {
                    let ratio = Double(dur) / Double(med)
                    if ratio > 0.55 && ratio < 1.8 {
                        score += 1.2
                    } else if ratio > 2.5 || ratio < 0.35 {
                        score -= 1.5
                    }
                }
                // Mild randomness so Refresh doesn't feel stuck.
                score *= Double.random(in: 0.85...1.15)
                return (song, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    private static func reasonFallback(for song: Song, profile: Profile) -> String {
        if let genre = song.genre, !genre.isEmpty {
            return "Fits \(genre)"
        }
        if let dominant = profile.dominantGenre {
            return "Fits \(dominant)"
        }
        return "Matches this playlist"
    }
}
