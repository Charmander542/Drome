import Foundation

/// Starts a radio from a song or artist and optionally saves it as a server playlist.
@MainActor
enum InstantMix {
    static func songs(from song: Song, client: SubsonicClient, count: Int = 40) async -> [Song] {
        var pool: [Song] = []
        if let artistId = song.artistId {
            pool += (try? await client.similarSongs(artistId: artistId, count: count)) ?? []
        }
        if pool.count < count / 2, let genre = song.genre {
            pool += (try? await client.songsByGenre(genre, count: count)) ?? []
        }
        if pool.count < 10 {
            pool += (try? await client.randomSongs(size: count)) ?? []
        }
        var seen = Set<String>([song.id])
        var result: [Song] = [song]
        for s in pool where seen.insert(s.id).inserted {
            result.append(s)
            if result.count >= count { break }
        }
        return result
    }

    static func songs(fromArtistId artistId: String, client: SubsonicClient, count: Int = 40) async -> [Song] {
        var pool = (try? await client.similarSongs(artistId: artistId, count: count)) ?? []
        if pool.count < count / 2 {
            pool += (try? await client.randomSongs(size: count)) ?? []
        }
        return Array(pool.uniquedByID().prefix(count))
    }

    /// Save the current radio as a playlist on the server (Aura Instant Mix save).
    @discardableResult
    static func saveAsPlaylist(
        name: String,
        songs: [Song],
        client: SubsonicClient
    ) async throws -> PlaylistWithSongs {
        try await client.createPlaylist(name: name, songIds: songs.map(\.id))
    }
}
