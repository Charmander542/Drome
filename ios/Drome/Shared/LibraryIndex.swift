import Foundation
import GRDB

/// One A–Z bucket shown in the library lists. The view never holds the full
/// catalog — only the letter(s) currently on screen, loaded from SQLite.
struct LibraryLetterSection<Item: Identifiable>: Identifiable {
    var id: String { letter }
    var letter: String
    var items: [Item]
}

enum LibraryIndexKind: String {
    case songs, albums, artists
}

/// Fast local library index (play:sub-style).
///
/// Network pages are upserted into SQLite; SwiftUI only queries one letter at
/// a time. That keeps memory and ForEach identity flat as the collection grows.
struct LibraryIndex: Sendable {
    let database: AppDatabase

    private static func encode<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ raw: String) -> T? {
        raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    func replaceSongs(_ songs: [Song], serverKey: String, isComplete: Bool) throws {
        try database.upsertLibraryJSON(
            kind: .songs, serverKey: serverKey, replace: true, isComplete: isComplete,
            rows: Self.songRows(songs))
    }

    func appendSongs(_ songs: [Song], serverKey: String, isComplete: Bool) throws {
        try database.upsertLibraryJSON(
            kind: .songs, serverKey: serverKey, replace: false, isComplete: isComplete,
            rows: Self.songRows(songs))
    }

    func songs(serverKey: String, letter: String) throws -> [Song] {
        try database.libraryJSON(kind: .songs, serverKey: serverKey, letter: letter)
            .compactMap { Self.decode(Song.self, $0) }
    }

    func songs(serverKey: String, startingAt id: String, limit: Int) throws -> [Song] {
        try database.libraryJSON(kind: .songs, serverKey: serverKey, startingAt: id, limit: limit)
            .compactMap { Self.decode(Song.self, $0) }
    }

    func song(serverKey: String, id: String) throws -> Song? {
        try database.libraryJSON(kind: .songs, serverKey: serverKey, id: id)
            .flatMap { Self.decode(Song.self, $0) }
    }

    // MARK: - Albums

    func replaceAlbums(_ albums: [Album], serverKey: String, isComplete: Bool) throws {
        try database.upsertLibraryJSON(
            kind: .albums, serverKey: serverKey, replace: true, isComplete: isComplete,
            rows: Self.albumRows(albums))
    }

    func appendAlbums(_ albums: [Album], serverKey: String, isComplete: Bool) throws {
        try database.upsertLibraryJSON(
            kind: .albums, serverKey: serverKey, replace: false, isComplete: isComplete,
            rows: Self.albumRows(albums))
    }

    func albums(serverKey: String, letter: String) throws -> [Album] {
        try database.libraryJSON(kind: .albums, serverKey: serverKey, letter: letter)
            .compactMap { Self.decode(Album.self, $0) }
    }

    // MARK: - Artists

    func replaceArtists(_ artists: [Artist], serverKey: String) throws {
        try database.upsertLibraryJSON(
            kind: .artists, serverKey: serverKey, replace: true, isComplete: true,
            rows: Self.artistRows(artists))
    }

    func artists(serverKey: String, letter: String) throws -> [Artist] {
        try database.libraryJSON(kind: .artists, serverKey: serverKey, letter: letter)
            .compactMap { Self.decode(Artist.self, $0) }
    }

    // MARK: - Shared queries

    func letters(kind: LibraryIndexKind, serverKey: String) throws -> [String] {
        let raw = try database.libraryLetters(kind: kind, serverKey: serverKey)
        return raw.sorted(by: LibrarySortLetter.sectionLetterSort)
    }

    func count(kind: LibraryIndexKind, serverKey: String) throws -> Int {
        try database.libraryCount(kind: kind, serverKey: serverKey)
    }

    func isComplete(kind: LibraryIndexKind, serverKey: String) throws -> Bool {
        try database.librarySyncComplete(kind: kind, serverKey: serverKey)
    }

    /// Instant in-app search over the local SQLite index (titles / names).
    func search(
        serverKey: String,
        query: String,
        artistLimit: Int = 12,
        albumLimit: Int = 16,
        songLimit: Int = 32
    ) throws -> SearchResult3 {
        let artists = try database.searchLibraryJSON(
            kind: .artists, serverKey: serverKey, query: query, limit: artistLimit)
            .compactMap { Self.decode(Artist.self, $0) }
        let albums = try database.searchLibraryJSON(
            kind: .albums, serverKey: serverKey, query: query, limit: albumLimit)
            .compactMap { Self.decode(Album.self, $0) }
        let songs = try database.searchLibraryJSON(
            kind: .songs, serverKey: serverKey, query: query, limit: songLimit)
            .compactMap { Self.decode(Song.self, $0) }
        return SearchResult3(artist: artists, album: albums, song: songs)
    }

    func clear(kind: LibraryIndexKind, serverKey: String) throws {
        try database.clearLibrary(kind: kind, serverKey: serverKey)
    }

    func clearAll(serverKey: String) throws {
        try database.clearLibrary(kind: .songs, serverKey: serverKey)
        try database.clearLibrary(kind: .albums, serverKey: serverKey)
        try database.clearLibrary(kind: .artists, serverKey: serverKey)
    }

    /// One-time import from the old JSON catalog so a filled cache isn't discarded.
    func importLegacyJSONIfNeeded(serverKey: String) {
        do {
            if try count(kind: .songs, serverKey: serverKey) == 0,
               let cached = LibraryListCatalog.songs(serverKey: serverKey),
               !cached.isEmpty {
                try replaceSongs(
                    cached, serverKey: serverKey,
                    isComplete: LibraryListCatalog.songsComplete(serverKey: serverKey))
            }
            if try count(kind: .albums, serverKey: serverKey) == 0,
               let cached = LibraryListCatalog.albums(serverKey: serverKey),
               !cached.isEmpty {
                try replaceAlbums(
                    cached, serverKey: serverKey,
                    isComplete: LibraryListCatalog.albumsComplete(serverKey: serverKey))
            }
            if try count(kind: .artists, serverKey: serverKey) == 0,
               let cached = LibraryListCatalog.artistSections(serverKey: serverKey),
               !cached.isEmpty {
                try replaceArtists(cached.flatMap(\.artists), serverKey: serverKey)
            }
            LibraryListCatalog.invalidateLists(serverKey: serverKey)
        } catch {
            // Best-effort — network fill still populates SQLite.
        }
    }

    // MARK: - Rows

    private static func songRows(_ songs: [Song]) -> [LibraryIndexRow] {
        songs.map { song in
            let sort = LibrarySortLetter.sortableName(song.title).lowercased()
            return LibraryIndexRow(
                id: song.id,
                sortKey: sort,
                letter: LibrarySortLetter.sectionLetter(for: song.title),
                json: encode(song))
        }
    }

    private static func albumRows(_ albums: [Album]) -> [LibraryIndexRow] {
        albums.map { album in
            let sort = LibrarySortLetter.sortableName(album.name).lowercased()
            return LibraryIndexRow(
                id: album.id,
                sortKey: sort,
                letter: LibrarySortLetter.sectionLetter(for: album.name),
                json: encode(album))
        }
    }

    private static func artistRows(_ artists: [Artist]) -> [LibraryIndexRow] {
        var seen = Set<String>()
        return artists.compactMap { artist in
            guard seen.insert(artist.id).inserted else { return nil }
            let sort = LibrarySortLetter.sortableName(artist.name).lowercased()
            return LibraryIndexRow(
                id: artist.id,
                sortKey: sort,
                letter: LibrarySortLetter.sectionLetter(for: artist.name),
                json: encode(artist))
        }
    }
}

struct LibraryIndexRow {
    var id: String
    var sortKey: String
    var letter: String
    var json: String
}

extension AppDatabase {
    fileprivate func table(for kind: LibraryIndexKind) -> (table: String, json: String) {
        switch kind {
        case .songs: return ("library_songs", "song_json")
        case .albums: return ("library_albums", "album_json")
        case .artists: return ("library_artists", "artist_json")
        }
    }

    func upsertLibraryJSON(
        kind: LibraryIndexKind,
        serverKey: String,
        replace: Bool,
        isComplete: Bool,
        rows: [LibraryIndexRow]
    ) throws {
        let names = table(for: kind)
        try pool.write { db in
            if replace {
                try db.execute(
                    sql: "DELETE FROM \(names.table) WHERE server_key = ?",
                    arguments: [serverKey])
            }
            let sql = """
                INSERT INTO \(names.table) (server_key, id, sort_key, letter, \(names.json))
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_key, id) DO UPDATE SET
                    sort_key = excluded.sort_key,
                    letter = excluded.letter,
                    \(names.json) = excluded.\(names.json)
                """
            for row in rows {
                try db.execute(sql: sql, arguments: [
                    serverKey, row.id, row.sortKey, row.letter, row.json
                ])
            }
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(names.table) WHERE server_key = ?",
                arguments: [serverKey]) ?? 0
            try db.execute(sql: """
                INSERT INTO library_sync (server_key, kind, is_complete, item_count, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_key, kind) DO UPDATE SET
                    is_complete = excluded.is_complete,
                    item_count = excluded.item_count,
                    updated_at = excluded.updated_at
                """, arguments: [
                    serverKey, kind.rawValue, isComplete ? 1 : 0, count,
                    Date().timeIntervalSince1970
                ])
        }
    }

    func libraryJSON(kind: LibraryIndexKind, serverKey: String, letter: String) throws -> [String] {
        let names = table(for: kind)
        return try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT \(names.json) FROM \(names.table)
                WHERE server_key = ? AND letter = ?
                ORDER BY sort_key, id
                """, arguments: [serverKey, letter])
        }
    }

    func libraryJSON(kind: LibraryIndexKind, serverKey: String, id: String) throws -> String? {
        let names = table(for: kind)
        return try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT \(names.json) FROM \(names.table)
                WHERE server_key = ? AND id = ?
                """, arguments: [serverKey, id])
        }
    }

    func libraryJSON(
        kind: LibraryIndexKind,
        serverKey: String,
        startingAt id: String,
        limit: Int
    ) throws -> [String] {
        let names = table(for: kind)
        return try pool.read { db in
            guard let sort = try String.fetchOne(db, sql: """
                SELECT sort_key FROM \(names.table) WHERE server_key = ? AND id = ?
                """, arguments: [serverKey, id]) else { return [] }
            return try String.fetchAll(db, sql: """
                SELECT \(names.json) FROM \(names.table)
                WHERE server_key = ?
                  AND (sort_key > ? OR (sort_key = ? AND id >= ?))
                ORDER BY sort_key, id
                LIMIT ?
                """, arguments: [serverKey, sort, sort, id, limit])
        }
    }

    func libraryLetters(kind: LibraryIndexKind, serverKey: String) throws -> [String] {
        let names = table(for: kind)
        return try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT letter FROM \(names.table) WHERE server_key = ?
                """, arguments: [serverKey])
        }
    }

    func libraryCount(kind: LibraryIndexKind, serverKey: String) throws -> Int {
        let names = table(for: kind)
        return try pool.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(names.table) WHERE server_key = ?",
                arguments: [serverKey]) ?? 0
        }
    }

    func searchLibraryJSON(
        kind: LibraryIndexKind,
        serverKey: String,
        query: String,
        limit: Int
    ) throws -> [String] {
        func cleaned(_ raw: String) -> String {
            raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .filter { $0 != "%" && $0 != "_" && $0 != "\\" }
        }
        let needle = cleaned(query)
        guard !needle.isEmpty else { return [] }
        let sortable = cleaned(LibrarySortLetter.sortableName(query))
        func like(_ value: String) -> String {
            value.count < 3 ? "\(value)%" : "%\(value)%"
        }
        let names = table(for: kind)
        return try pool.read { db in
            try String.fetchAll(db, sql: """
                SELECT \(names.json) FROM \(names.table)
                WHERE server_key = ?
                  AND (sort_key LIKE ? OR sort_key LIKE ?)
                ORDER BY CASE WHEN sort_key LIKE ? THEN 0 ELSE 1 END, sort_key, id
                LIMIT ?
                """, arguments: [
                    serverKey,
                    like(needle),
                    like(sortable.isEmpty ? needle : sortable),
                    "\(needle)%",
                    limit
                ])
        }
    }

    func librarySyncComplete(kind: LibraryIndexKind, serverKey: String) throws -> Bool {
        try pool.read { db in
            let flag = try Int.fetchOne(db, sql: """
                SELECT is_complete FROM library_sync WHERE server_key = ? AND kind = ?
                """, arguments: [serverKey, kind.rawValue]) ?? 0
            return flag != 0
        }
    }

    func clearLibrary(kind: LibraryIndexKind, serverKey: String) throws {
        let names = table(for: kind)
        try pool.write { db in
            try db.execute(
                sql: "DELETE FROM \(names.table) WHERE server_key = ?",
                arguments: [serverKey])
            try db.execute(sql: """
                DELETE FROM library_sync WHERE server_key = ? AND kind = ?
                """, arguments: [serverKey, kind.rawValue])
        }
    }
}
