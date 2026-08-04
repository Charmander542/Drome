import Foundation
import GRDB

struct CachedLyrics {
    var serverKey: String
    var songId: String
    var title: String
    var artist: String
    var album: String
    var synced: Bool
    /// Raw lyrics text: LRC when synced, plain text otherwise.
    var content: String
    var source: String // "navidrome" | "lrclib" | "none"
}

struct LyricsSearchMatch: Identifiable {
    var id: String { songId }
    var songId: String
    var title: String
    var artist: String
    var album: String
    var snippet: String
}

struct DownloadRecord {
    var serverKey: String
    var songId: String
    var songJSON: String
    var albumId: String
    var albumName: String
    var artist: String
    var state: String // queued | downloading | done | failed
    var relPath: String?
    var fileSize: Int64
}

/// On-device SQLite database (GRDB): lyrics cache, FTS5 lyrics search index,
/// offline-download metadata, and Out-of-Rotation manual overrides.
final class AppDatabase {
    let pool: DatabasePool

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        pool = try DatabasePool(path: url.path)
        try migrator.migrate(pool)
    }

    static func makeShared() -> AppDatabase {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = support.appendingPathComponent("Drome/drome.sqlite")
        do {
            return try AppDatabase(url: url)
        } catch {
            fatalError("Could not open database: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE lyrics (
                    server_key TEXT NOT NULL,
                    song_id    TEXT NOT NULL,
                    title      TEXT NOT NULL DEFAULT '',
                    artist     TEXT NOT NULL DEFAULT '',
                    album      TEXT NOT NULL DEFAULT '',
                    synced     INTEGER NOT NULL DEFAULT 0,
                    content    TEXT NOT NULL DEFAULT '',
                    source     TEXT NOT NULL DEFAULT 'none',
                    fetched_at TEXT NOT NULL,
                    PRIMARY KEY (server_key, song_id)
                );
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE lyrics_fts USING fts5(
                    server_key UNINDEXED,
                    song_id UNINDEXED,
                    title,
                    artist,
                    album UNINDEXED,
                    content,
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)
            try db.execute(sql: """
                CREATE TABLE downloads (
                    server_key TEXT NOT NULL,
                    song_id    TEXT NOT NULL,
                    song_json  TEXT NOT NULL,
                    album_id   TEXT NOT NULL DEFAULT '',
                    album_name TEXT NOT NULL DEFAULT '',
                    artist     TEXT NOT NULL DEFAULT '',
                    state      TEXT NOT NULL DEFAULT 'queued',
                    rel_path   TEXT,
                    file_size  INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    PRIMARY KEY (server_key, song_id)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE rotation_overrides (
                    user_key TEXT NOT NULL,
                    song_id  TEXT NOT NULL,
                    kind     TEXT NOT NULL, -- manual_add | manual_remove | auto
                    PRIMARY KEY (user_key, song_id)
                );
                """)
            try db.execute(sql: """
                CREATE TABLE lyrics_index_state (
                    server_key   TEXT PRIMARY KEY,
                    album_offset INTEGER NOT NULL DEFAULT 0,
                    updated_at   TEXT NOT NULL
                );
                """)
        }
        return migrator
    }

    // MARK: - Lyrics cache

    func cachedLyrics(serverKey: String, songId: String) throws -> CachedLyrics? {
        try pool.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT * FROM lyrics WHERE server_key = ? AND song_id = ?
                """, arguments: [serverKey, songId]) else { return nil }
            return CachedLyrics(serverKey: row["server_key"], songId: row["song_id"],
                                title: row["title"], artist: row["artist"], album: row["album"],
                                synced: row["synced"], content: row["content"], source: row["source"])
        }
    }

    func storeLyrics(_ lyrics: CachedLyrics) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO lyrics (server_key, song_id, title, artist, album, synced, content, source, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (server_key, song_id) DO UPDATE SET
                    title = excluded.title, artist = excluded.artist, album = excluded.album,
                    synced = excluded.synced, content = excluded.content,
                    source = excluded.source, fetched_at = excluded.fetched_at
                """, arguments: [lyrics.serverKey, lyrics.songId, lyrics.title, lyrics.artist,
                                 lyrics.album, lyrics.synced, lyrics.content, lyrics.source,
                                 ISO8601DateFormatter().string(from: Date())])

            try db.execute(sql: "DELETE FROM lyrics_fts WHERE server_key = ? AND song_id = ?",
                           arguments: [lyrics.serverKey, lyrics.songId])
            guard lyrics.source != "none", !lyrics.content.isEmpty else { return }
            // Index plain text (timestamps stripped) for deep search.
            let plain = LRCParser.plainText(from: lyrics.content)
            try db.execute(sql: """
                INSERT INTO lyrics_fts (server_key, song_id, title, artist, album, content)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [lyrics.serverKey, lyrics.songId, lyrics.title, lyrics.artist,
                                 lyrics.album, plain])
        }
    }

    /// Approximate full-text search over cached lyrics. Each word is matched
    /// as a prefix so partially remembered lines still hit.
    func searchLyrics(serverKey: String, query: String, limit: Int = 40) throws -> [LyricsSearchMatch] {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .map { "\"\($0)\"*" }
        guard !tokens.isEmpty else { return [] }
        let match = tokens.joined(separator: " ")

        return try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT song_id, title, artist, album,
                       snippet(lyrics_fts, 5, '', '', ' … ', 14) AS snip
                FROM lyrics_fts
                WHERE lyrics_fts MATCH ? AND server_key = ?
                ORDER BY bm25(lyrics_fts, 0, 2.0, 1.0, 0, 4.0)
                LIMIT ?
                """, arguments: [match, serverKey, limit])
            return rows.map {
                LyricsSearchMatch(songId: $0["song_id"], title: $0["title"],
                                  artist: $0["artist"], album: $0["album"], snippet: $0["snip"])
            }
        }
    }

    func lyricsCount(serverKey: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM lyrics WHERE server_key = ? AND source != 'none'
                """, arguments: [serverKey]) ?? 0
        }
    }

    // MARK: - Downloads

    func upsertDownload(_ record: DownloadRecord) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO downloads (server_key, song_id, song_json, album_id, album_name,
                                       artist, state, rel_path, file_size, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (server_key, song_id) DO UPDATE SET
                    song_json = excluded.song_json, album_id = excluded.album_id,
                    album_name = excluded.album_name, artist = excluded.artist,
                    state = excluded.state, rel_path = excluded.rel_path,
                    file_size = excluded.file_size
                """, arguments: [record.serverKey, record.songId, record.songJSON, record.albumId,
                                 record.albumName, record.artist, record.state, record.relPath,
                                 record.fileSize, ISO8601DateFormatter().string(from: Date())])
        }
    }

    func setDownloadState(serverKey: String, songId: String, state: String,
                          relPath: String? = nil, fileSize: Int64? = nil) throws {
        try pool.write { db in
            try db.execute(sql: """
                UPDATE downloads SET state = ?,
                    rel_path = COALESCE(?, rel_path),
                    file_size = COALESCE(?, file_size)
                WHERE server_key = ? AND song_id = ?
                """, arguments: [state, relPath, fileSize, serverKey, songId])
        }
    }

    func downloadRecords(serverKey: String) throws -> [DownloadRecord] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM downloads WHERE server_key = ? ORDER BY album_name, song_id
                """, arguments: [serverKey])
            return rows.map {
                DownloadRecord(serverKey: $0["server_key"], songId: $0["song_id"],
                               songJSON: $0["song_json"], albumId: $0["album_id"],
                               albumName: $0["album_name"], artist: $0["artist"],
                               state: $0["state"], relPath: $0["rel_path"], fileSize: $0["file_size"])
            }
        }
    }

    func deleteDownload(serverKey: String, songId: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM downloads WHERE server_key = ? AND song_id = ?",
                           arguments: [serverKey, songId])
        }
    }

    // MARK: - Rotation overrides

    func rotationOverride(userKey: String, songId: String) throws -> String? {
        try pool.read { db in
            try String.fetchOne(db, sql: """
                SELECT kind FROM rotation_overrides WHERE user_key = ? AND song_id = ?
                """, arguments: [userKey, songId])
        }
    }

    func setRotationOverride(userKey: String, songId: String, kind: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO rotation_overrides (user_key, song_id, kind) VALUES (?, ?, ?)
                ON CONFLICT (user_key, song_id) DO UPDATE SET kind = excluded.kind
                """, arguments: [userKey, songId, kind])
        }
    }

    func clearRotationOverride(userKey: String, songId: String) throws {
        try pool.write { db in
            try db.execute(sql: "DELETE FROM rotation_overrides WHERE user_key = ? AND song_id = ?",
                           arguments: [userKey, songId])
        }
    }

    // MARK: - Lyrics indexer progress

    func lyricsIndexOffset(serverKey: String) throws -> Int {
        try pool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT album_offset FROM lyrics_index_state WHERE server_key = ?
                """, arguments: [serverKey]) ?? 0
        }
    }

    func setLyricsIndexOffset(serverKey: String, offset: Int) throws {
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO lyrics_index_state (server_key, album_offset, updated_at) VALUES (?, ?, ?)
                ON CONFLICT (server_key) DO UPDATE SET
                    album_offset = excluded.album_offset, updated_at = excluded.updated_at
                """, arguments: [serverKey, offset, ISO8601DateFormatter().string(from: Date())])
        }
    }
}
