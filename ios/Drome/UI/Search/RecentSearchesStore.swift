import Foundation

/// A library item the user opened or played from Search.
struct RecentSearchItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case artist, album, song, playlist
    }

    var kind: Kind
    var entityId: String
    var title: String
    var subtitle: String
    var coverArt: String?
    /// Encoded entity so we can reopen / replay without another network hop.
    var payloadJSON: String?

    var id: String { "\(kind.rawValue):\(entityId)" }

    static func from(hit: SearchHit) -> RecentSearchItem? {
        switch hit.kind {
        case .artist:
            guard let artist = hit.artist else { return nil }
            return RecentSearchItem(
                kind: .artist,
                entityId: artist.id,
                title: hit.title,
                subtitle: hit.subtitle,
                coverArt: hit.coverArt,
                payloadJSON: encode(artist))
        case .album:
            guard let album = hit.album else { return nil }
            return RecentSearchItem(
                kind: .album,
                entityId: album.id,
                title: hit.title,
                subtitle: hit.subtitle,
                coverArt: hit.coverArt,
                payloadJSON: encode(album))
        case .song:
            guard let song = hit.song else { return nil }
            return RecentSearchItem(
                kind: .song,
                entityId: song.id,
                title: hit.title,
                subtitle: hit.subtitle,
                coverArt: hit.coverArt,
                payloadJSON: encode(song))
        case .playlist:
            guard let playlist = hit.playlist else { return nil }
            return RecentSearchItem(
                kind: .playlist,
                entityId: playlist.id,
                title: hit.title,
                subtitle: hit.subtitle,
                coverArt: hit.coverArt,
                payloadJSON: encode(playlist))
        }
    }

    static func from(song: Song) -> RecentSearchItem {
        let subtitle = [song.displayArtist, song.album, "Song"]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return RecentSearchItem(
            kind: .song,
            entityId: song.id,
            title: song.title,
            subtitle: subtitle,
            coverArt: song.coverArt ?? song.albumId,
            payloadJSON: encode(song))
    }

    /// Cached so List rows don’t JSON-decode on every body pass while scrolling.
    private static var songCache: [String: Song] = [:]
    private static var albumCache: [String: Album] = [:]
    private static var artistCache: [String: Artist] = [:]
    private static var playlistCache: [String: Playlist] = [:]

    func decodedSong() -> Song? {
        guard kind == .song else { return nil }
        if let cached = Self.songCache[entityId] { return cached }
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let song = try? JSONDecoder().decode(Song.self, from: data)
        else { return nil }
        Self.songCache[entityId] = song
        return song
    }

    func decodedAlbum() -> Album? {
        guard kind == .album else { return nil }
        if let cached = Self.albumCache[entityId] { return cached }
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let album = try? JSONDecoder().decode(Album.self, from: data)
        else { return nil }
        Self.albumCache[entityId] = album
        return album
    }

    func decodedArtist() -> Artist? {
        guard kind == .artist else { return nil }
        if let cached = Self.artistCache[entityId] { return cached }
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let artist = try? JSONDecoder().decode(Artist.self, from: data)
        else { return nil }
        Self.artistCache[entityId] = artist
        return artist
    }

    func decodedPlaylist() -> Playlist? {
        guard kind == .playlist else { return nil }
        if let cached = Self.playlistCache[entityId] { return cached }
        guard let payloadJSON,
              let data = payloadJSON.data(using: .utf8),
              let playlist = try? JSONDecoder().decode(Playlist.self, from: data)
        else { return nil }
        Self.playlistCache[entityId] = playlist
        return playlist
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Persists recent Search *selections* (not typed queries).
enum RecentSearchesStore {
    private static let key = "drome.recentSearchItems"
    private static let legacyKey = "drome.recentSearches"
    private static let limit = 20

    static func load() -> [RecentSearchItem] {
        // Drop legacy query-string history once.
        if UserDefaults.standard.object(forKey: legacyKey) != nil {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
        guard let data = UserDefaults.standard.data(forKey: key),
              let items = try? JSONDecoder().decode([RecentSearchItem].self, from: data)
        else { return [] }
        return items
    }

    static func remember(_ item: RecentSearchItem) {
        var items = load().filter { $0.id != item.id }
        items.insert(item, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        save(items)
    }

    static func remember(hit: SearchHit) {
        guard let item = RecentSearchItem.from(hit: hit) else { return }
        remember(item)
    }

    static func remember(song: Song) {
        remember(RecentSearchItem.from(song: song))
    }

    static func remove(_ item: RecentSearchItem) {
        save(load().filter { $0.id != item.id })
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ items: [RecentSearchItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
