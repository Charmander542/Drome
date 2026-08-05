import Foundation

/// A library item the user opened or played from Search.
struct RecentSearchItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case artist, album, song
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
        case .lyrics:
            guard let lyric = hit.lyrics else { return nil }
            // Treat lyrics hits as the underlying song.
            return RecentSearchItem(
                kind: .song,
                entityId: lyric.songId,
                title: lyric.title,
                subtitle: [lyric.artist, lyric.album, "Song"]
                    .filter { !$0.isEmpty }
                    .joined(separator: " · "),
                coverArt: nil,
                payloadJSON: nil)
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

    func decodedSong() -> Song? {
        guard kind == .song, let payloadJSON,
              let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Song.self, from: data)
    }

    func decodedAlbum() -> Album? {
        guard kind == .album, let payloadJSON,
              let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Album.self, from: data)
    }

    func decodedArtist() -> Artist? {
        guard kind == .artist, let payloadJSON,
              let data = payloadJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Artist.self, from: data)
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
