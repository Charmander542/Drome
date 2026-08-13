import Foundation

/// In-memory detail payloads so popping back into an album/playlist/artist
/// paints instantly while a background refresh updates the content.
enum LibraryDetailCache {
    private static let lock = NSLock()
    private static var albums: [String: AlbumWithSongs] = [:]
    private static var playlists: [String: PlaylistWithSongs] = [:]
    private static var artists: [String: (artist: ArtistWithAlbums, topSongs: [Song], owned: [Song])] = [:]

    static func album(_ id: String) -> AlbumWithSongs? {
        lock.lock(); defer { lock.unlock() }
        return albums[id]
    }

    static func store(album: AlbumWithSongs) {
        lock.lock(); defer { lock.unlock() }
        albums[album.id] = album
    }

    static func playlist(_ id: String) -> PlaylistWithSongs? {
        lock.lock(); defer { lock.unlock() }
        return playlists[id]
    }

    static func store(playlist: PlaylistWithSongs) {
        lock.lock(); defer { lock.unlock() }
        playlists[playlist.id] = playlist
    }

    static func artist(_ id: String) -> (artist: ArtistWithAlbums, topSongs: [Song], owned: [Song])? {
        lock.lock(); defer { lock.unlock() }
        return artists[id]
    }

    static func store(artist: ArtistWithAlbums, topSongs: [Song], owned: [Song]) {
        lock.lock(); defer { lock.unlock() }
        artists[artist.id] = (artist, topSongs, owned)
    }
}
