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
/// offline-download metadata, Out-of-Rotation manual overrides, and play history.
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
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE play_history (
                    user_key   TEXT NOT NULL,
                    song_id    TEXT NOT NULL,
                    played_at  REAL NOT NULL,
                    song_json  TEXT NOT NULL
                );
                """)
            try db.execute(sql: """
                CREATE INDEX play_history_user_played_at
                ON play_history (user_key, played_at DESC);
                """)
        }
        migrator.registerMigration("v3_play_context") { db in
            try db.execute(sql: """
                ALTER TABLE play_history ADD COLUMN context_kind TEXT;
                """)
            try db.execute(sql: """
                ALTER TABLE play_history ADD COLUMN context_id TEXT;
                """)
            try db.execute(sql: """
                ALTER TABLE play_history ADD COLUMN context_label TEXT;
                """)
        }
        migrator.registerMigration("v4_song_ratings") { db in
            try db.execute(sql: """
                CREATE TABLE song_ratings (
                    user_key   TEXT NOT NULL,
                    song_id    TEXT NOT NULL,
                    rating     INTEGER NOT NULL,
                    song_json  TEXT NOT NULL,
                    updated_at REAL NOT NULL,
                    PRIMARY KEY (user_key, song_id)
                );
                """)
            try db.execute(sql: """
                CREATE INDEX song_ratings_user_rating
                ON song_ratings (user_key, rating DESC);
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

    // MARK: - Play history

    /// Records a play and retains at most the newest 500 rows for the user.
    func recordPlay(userKey: String, song: Song, context: PlaybackContext? = nil) throws {
        let json = (try? JSONEncoder().encode(song))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let playedAt = Date().timeIntervalSince1970
        let kind: String?
        let contextId: String?
        let label: String?
        switch context?.kind {
        case .playlist(let id):
            kind = "playlist"
            contextId = id
            label = context?.label
        case .album:
            kind = "album"
            contextId = song.albumId
            label = context?.label ?? song.album
        case .artist:
            kind = "artist"
            contextId = song.artistId ?? context?.label
            label = context?.label
        case .genre:
            kind = "genre"
            contextId = context?.label
            label = context?.label
        case .search:
            kind = "search"
            contextId = nil
            label = context?.label
        case .mix:
            kind = "mix"
            // Stable key so "Chill" / "5 Stars" collapse across many tracks.
            contextId = context?.label
            label = context?.label
        case .outOfRotation:
            kind = "outOfRotation"
            contextId = "outOfRotation"
            label = context?.label ?? RotationManager.playlistName
        case .none:
            kind = nil
            contextId = nil
            label = nil
        }
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO play_history
                    (user_key, song_id, played_at, song_json, context_kind, context_id, context_label)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [userKey, song.id, playedAt, json, kind, contextId, label])
            try db.execute(sql: """
                DELETE FROM play_history
                WHERE user_key = ?
                  AND rowid NOT IN (
                    SELECT rowid FROM play_history
                    WHERE user_key = ?
                    ORDER BY played_at DESC
                    LIMIT 500
                  )
                """, arguments: [userKey, userKey])
        }
    }

    /// Most-recent-first plays, unique by `song_id` (keeps the newest row).
    func recentPlays(userKey: String, limit: Int = 50) throws -> [Song] {
        try recentPlayEntries(userKey: userKey, limit: limit).compactMap {
            if case .song(let song) = $0 { return song }
            return nil
        }
    }

    /// Home “Recently played” rail.
    ///
    /// - Playlists / albums / vibes / genres / artists collapse to one card.
    /// - Individual songs only when the play came from search (or no context).
    /// - Silent Autoplay extensions are omitted — the user didn’t pick them.
    func recentPlayEntries(userKey: String, limit: Int = 40) throws -> [RecentPlayEntry] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT song_id, song_json, context_kind, context_id, context_label
                FROM play_history
                WHERE user_key = ?
                ORDER BY played_at DESC
                LIMIT 500
                """, arguments: [userKey])

            var entries: [RecentPlayEntry] = []
            var seen = Set<String>()

            for row in rows {
                let json: String = row["song_json"]
                guard let data = json.data(using: .utf8),
                      let song = try? JSONDecoder().decode(Song.self, from: data) else { continue }

                let kind: String? = row["context_kind"]
                let contextId: String? = row["context_id"]
                let label: String? = row["context_label"]
                let name = (label?.isEmpty == false) ? label! : nil

                // Infinite Shuffle refill — not a user-chosen source.
                if kind == "mix", (name == "Autoplay" || name == "Recently played") {
                    continue
                }

                let entry: RecentPlayEntry?
                switch kind {
                case "playlist":
                    guard let playlistId = contextId, !playlistId.isEmpty else { entry = nil; break }
                    entry = .playlist(
                        id: playlistId,
                        name: name ?? "Playlist",
                        coverSong: song)

                case "album":
                    guard let albumId = contextId ?? song.albumId, !albumId.isEmpty else {
                        // No album id — fall back to the track.
                        entry = .song(song)
                        break
                    }
                    entry = .album(
                        id: albumId,
                        name: name ?? song.album ?? "Album",
                        coverSong: song)

                case "mix", "genre", "artist", "outOfRotation":
                    let key = (contextId?.isEmpty == false ? contextId! : nil)
                        ?? name
                        ?? kind
                        ?? "mix"
                    let subtitle: String = {
                        switch kind {
                        case "genre": return "Genre"
                        case "artist": return "Artist"
                        case "outOfRotation": return "Playlist"
                        default: return "Mix"
                        }
                    }()
                    entry = .mix(
                        key: "\(kind ?? "mix"):\(key)",
                        name: name ?? key,
                        coverSong: song,
                        subtitle: subtitle)

                case "search", .none:
                    // Explicit track pick (search) or legacy rows without context.
                    entry = .song(song)

                default:
                    entry = .song(song)
                }

                guard let entry else { continue }
                guard seen.insert(entry.id).inserted else { continue }
                entries.append(entry)
                if entries.count >= limit { break }
            }
            return entries
        }
    }

    /// Song IDs played within the given lookback window (default 72 hours).
    func recentPlayIDs(userKey: String, withinHours: Double = 72) throws -> Set<String> {
        let cutoff = Date().timeIntervalSince1970 - withinHours * 3600
        return try pool.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT DISTINCT song_id FROM play_history
                WHERE user_key = ? AND played_at >= ?
                """, arguments: [userKey, cutoff])
            return Set(ids)
        }
    }

    // MARK: - Song ratings (local index for Rated collections)

    func upsertSongRating(userKey: String, song: Song, rating: Int) throws {
        let clamped = min(5, max(0, rating))
        if clamped == 0 {
            try clearSongRating(userKey: userKey, songId: song.id)
            return
        }
        let json = (try? JSONEncoder().encode(song))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let updatedAt = Date().timeIntervalSince1970
        try pool.write { db in
            try db.execute(sql: """
                INSERT INTO song_ratings (user_key, song_id, rating, song_json, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (user_key, song_id) DO UPDATE SET
                    rating = excluded.rating,
                    song_json = excluded.song_json,
                    updated_at = excluded.updated_at
                """, arguments: [userKey, song.id, clamped, json, updatedAt])
        }
    }

    func clearSongRating(userKey: String, songId: String) throws {
        try pool.write { db in
            try db.execute(sql: """
                DELETE FROM song_ratings WHERE user_key = ? AND song_id = ?
                """, arguments: [userKey, songId])
        }
    }

    /// All locally indexed ratings for a user (song_id → rating).
    func allSongRatings(userKey: String) throws -> [String: Int] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT song_id, rating FROM song_ratings WHERE user_key = ?
                """, arguments: [userKey])
            var map: [String: Int] = [:]
            for row in rows {
                let id: String = row["song_id"]
                let rating: Int = row["rating"]
                map[id] = rating
            }
            return map
        }
    }

    /// Songs with rating ≥ minRating, highest first.
    func ratedSongs(userKey: String, minRating: Int, limit: Int = 500) throws -> [Song] {
        try pool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT song_json, rating FROM song_ratings
                WHERE user_key = ? AND rating >= ?
                ORDER BY rating DESC, updated_at DESC
                LIMIT ?
                """, arguments: [userKey, minRating, limit])
            return rows.compactMap { row -> Song? in
                let json: String = row["song_json"]
                guard let data = json.data(using: .utf8),
                      var song = try? JSONDecoder().decode(Song.self, from: data) else { return nil }
                let rating: Int = row["rating"]
                song.userRating = rating
                return song
            }
        }
    }

    /// Albums ranked by average of locally indexed track ratings.
    func topRatedAlbumsFromSongs(userKey: String, limit: Int = 80) throws -> [Album] {
        let songs = try ratedSongs(userKey: userKey, minRating: 1, limit: 2000)
        var buckets: [String: (name: String, artist: String?, cover: String?, sum: Int, count: Int)] = [:]
        for song in songs {
            guard let albumId = song.albumId, !albumId.isEmpty else { continue }
            let rating = song.userRating ?? 0
            guard rating > 0 else { continue }
            var bucket = buckets[albumId] ?? (
                name: song.album ?? "Album",
                artist: song.displayArtist,
                cover: song.coverArt,
                sum: 0,
                count: 0
            )
            if bucket.name.isEmpty { bucket.name = song.album ?? "Album" }
            if bucket.cover == nil { bucket.cover = song.coverArt }
            bucket.sum += rating
            bucket.count += 1
            buckets[albumId] = bucket
        }
        return buckets
            .map { id, b -> (Album, Double) in
                let avg = Double(b.sum) / Double(max(b.count, 1))
                var album = Album(
                    id: id,
                    name: b.name,
                    artist: b.artist,
                    artistId: nil,
                    coverArt: b.cover,
                    songCount: b.count,
                    duration: nil,
                    playCount: nil,
                    created: nil,
                    year: nil,
                    genre: nil,
                    userRating: Int(avg.rounded())
                )
                return (album, avg)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
            }
            .prefix(limit)
            .map(\.0)
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
