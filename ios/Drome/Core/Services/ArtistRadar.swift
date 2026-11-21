import Foundation

/// “New from artists you play” shelf — Radar without Deezer previews.
/// Uses newest albums filtered to artists present in recent plays.
@MainActor
enum ArtistRadar {
    static func albums(
        client: SubsonicClient,
        recent: [RecentPlayEntry],
        newest: [Album],
        limit: Int = 12
    ) async -> [Album] {
        var artistIDs = Set<String>()
        var artistNames = Set<String>()
        for entry in recent {
            switch entry {
            case .song(let song):
                if let id = song.artistId, !id.isEmpty { artistIDs.insert(id) }
                if let name = song.artist, !name.isEmpty { artistNames.insert(name.lowercased()) }
            case .album(_, _, let coverSong), .playlist(_, _, let coverSong), .mix(_, _, let coverSong, _):
                if let id = coverSong.artistId, !id.isEmpty { artistIDs.insert(id) }
                if let name = coverSong.artist, !name.isEmpty { artistNames.insert(name.lowercased()) }
            }
        }

        let matched = newest.filter { album in
            if let id = album.artistId, artistIDs.contains(id) { return true }
            if let name = album.artist?.lowercased(), artistNames.contains(name) { return true }
            return false
        }
        if !matched.isEmpty {
            return Array(matched.prefix(limit))
        }

        let extra = (try? await client.albumList(type: .newest, size: 40, offset: newest.count)) ?? []
        let more = extra.filter { album in
            if let id = album.artistId, artistIDs.contains(id) { return true }
            if let name = album.artist?.lowercased(), artistNames.contains(name) { return true }
            return false
        }
        return Array((matched + more).prefix(limit))
    }
}
