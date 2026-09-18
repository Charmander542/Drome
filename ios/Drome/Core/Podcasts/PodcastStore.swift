import Foundation
import GRDB

/// SQLite-backed store for podcast subscriptions and episode playback positions.
final class PodcastStore: @unchecked Sendable {
    private let db: DatabaseQueue

    init(dbPath: String) throws {
        let url = URL(fileURLWithPath: dbPath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        db = try DatabaseQueue(path: url.path)
        try migrator.migrate(db)
    }

    static func makeDefault() -> PodcastStore {
        let root: URL = {
            #if os(tvOS)
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Drome", isDirectory: true)
            #else
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Drome", isDirectory: true)
            #endif
        }()
        let path = root.appendingPathComponent("podcasts.sqlite").path
        do {
            return try PodcastStore(dbPath: path)
        } catch {
            fatalError("Could not open podcast database: \(error)")
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("podcasts_v1") { db in
            // Podcast subscriptions
            try db.execute(sql: """
                CREATE TABLE podcast_shows (
                    feed_url     TEXT PRIMARY KEY,
                    title        TEXT NOT NULL DEFAULT '',
                    author       TEXT,
                    description  TEXT,
                    image_url    TEXT,
                    language     TEXT,
                    category     TEXT,
                    explicit     INTEGER NOT NULL DEFAULT 0,
                    link         TEXT,
                    episode_count INTEGER NOT NULL DEFAULT 0,
                    last_updated REAL,
                    subscribed_at REAL NOT NULL DEFAULT 0
                );
                """)

            // Episodes
            try db.execute(sql: """
                CREATE TABLE podcast_episodes (
                    id              TEXT NOT NULL,
                    show_feed_url   TEXT NOT NULL,
                    title           TEXT NOT NULL DEFAULT '',
                    description     TEXT,
                    pub_date        REAL,
                    duration        REAL,
                    audio_url       TEXT NOT NULL,
                    image_url       TEXT,
                    episode_number  INTEGER,
                    season_number   INTEGER,
                    episode_type    TEXT,
                    explicit        INTEGER NOT NULL DEFAULT 0,
                    file_size       INTEGER,
                    mime_type       TEXT,
                    PRIMARY KEY (id, show_feed_url),
                    FOREIGN KEY (show_feed_url) REFERENCES podcast_shows(feed_url) ON DELETE CASCADE
                );
                """)

            // Playback positions
            try db.execute(sql: """
                CREATE TABLE podcast_playback (
                    episode_id      TEXT NOT NULL,
                    show_feed_url   TEXT NOT NULL,
                    position        REAL NOT NULL DEFAULT 0,
                    last_played     REAL,
                    completed       INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (episode_id, show_feed_url),
                    FOREIGN KEY (episode_id, show_feed_url) REFERENCES podcast_episodes(id, show_feed_url) ON DELETE CASCADE
                );
                """)

            try db.execute(sql: """
                CREATE INDEX podcast_episodes_show ON podcast_episodes(show_feed_url, pub_date DESC);
                """)

            try db.execute(sql: """
                CREATE INDEX podcast_playback_last ON podcast_playback(last_played DESC);
                """)
        }
        migrator.registerMigration("podcasts_v2_stars") { db in
            try db.execute(sql: """
                CREATE TABLE podcast_stars (
                    episode_id      TEXT NOT NULL,
                    show_feed_url   TEXT NOT NULL,
                    starred_at      REAL NOT NULL,
                    PRIMARY KEY (episode_id, show_feed_url),
                    FOREIGN KEY (episode_id, show_feed_url)
                        REFERENCES podcast_episodes(id, show_feed_url) ON DELETE CASCADE
                );
                """)
            try db.execute(sql: """
                CREATE INDEX podcast_stars_starred_at ON podcast_stars(starred_at DESC);
                """)
        }
        migrator.registerMigration("podcasts_v3_chapters") { db in
            try db.execute(sql: """
                ALTER TABLE podcast_episodes ADD COLUMN chapters_url TEXT;
                """)
            try db.execute(sql: """
                ALTER TABLE podcast_episodes ADD COLUMN chapters_json TEXT;
                """)
        }
        return migrator
    }

    // MARK: - Subscriptions

    func subscribedShows() throws -> [PodcastShow] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT * FROM podcast_shows ORDER BY title COLLATE NOCASE
                """)
            return rows.map { row in
                let feedURL: String = row["feed_url"]
                let title: String = row["title"]
                let author: String? = row["author"]
                let description: String? = row["description"]
                let imageURLString: String? = row["image_url"]
                let language: String? = row["language"]
                let category: String? = row["category"]
                let explicitInt: Int = row["explicit"]
                let linkString: String? = row["link"]
                let episodeCount: Int = row["episode_count"]
                let lastUpdatedDouble: Double? = row["last_updated"]

                return PodcastShow(
                    id: feedURL,
                    title: title,
                    author: author,
                    description: description,
                    imageURL: imageURLString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    language: language,
                    category: category,
                    explicit: explicitInt == 1,
                    link: linkString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    episodeCount: episodeCount,
                    lastUpdated: lastUpdatedDouble.map { Date(timeIntervalSince1970: $0) },
                    feedURL: feedURL
                )
            }
        }
    }

    func isSubscribed(feedURL: String) throws -> Bool {
        try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM podcast_shows WHERE feed_url = ?
                """, arguments: [feedURL]) ?? 0 > 0
        }
    }

    func subscribe(_ show: PodcastShow) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO podcast_shows (feed_url, title, author, description, image_url,
                                           language, category, explicit, link, episode_count,
                                           last_updated, subscribed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (feed_url) DO UPDATE SET
                    title = excluded.title,
                    author = excluded.author,
                    description = excluded.description,
                    image_url = excluded.image_url,
                    language = excluded.language,
                    category = excluded.category,
                    explicit = excluded.explicit,
                    link = excluded.link,
                    episode_count = excluded.episode_count,
                    last_updated = excluded.last_updated
                """, arguments: StatementArguments([
                    show.feedURL, show.title,
                    show.author, show.description,
                    show.imageURL?.absoluteString,
                    show.language, show.category,
                    show.explicit ? 1 : 0,
                    show.link?.absoluteString,
                    show.episodeCount,
                    show.lastUpdated?.timeIntervalSince1970,
                    Date().timeIntervalSince1970
                ]) ?? [])
        }
    }

    func unsubscribe(feedURL: String) throws {
        try db.write { db in
            try db.execute(sql: """
                DELETE FROM podcast_shows WHERE feed_url = ?
                """, arguments: [feedURL])
        }
    }

    func updateShow(_ show: PodcastShow) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE podcast_shows SET
                    title = ?, author = ?, description = ?, image_url = ?,
                    language = ?, category = ?, explicit = ?, link = ?,
                    episode_count = ?, last_updated = ?
                WHERE feed_url = ?
                """, arguments: StatementArguments([
                    show.title, show.author, show.description,
                    show.imageURL?.absoluteString,
                    show.language, show.category,
                    show.explicit ? 1 : 0,
                    show.link?.absoluteString,
                    show.episodeCount,
                    show.lastUpdated?.timeIntervalSince1970,
                    show.feedURL
                ]) ?? [])
        }
    }

    // MARK: - Episodes

    func episodes(for feedURL: String, limit: Int = 200) throws -> [PodcastEpisode] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.*,
                       COALESCE(p.position, 0) as playback_position,
                       CASE WHEN s.episode_id IS NULL THEN 0 ELSE 1 END as is_starred
                FROM podcast_episodes e
                LEFT JOIN podcast_playback p
                    ON e.id = p.episode_id AND e.show_feed_url = p.show_feed_url
                LEFT JOIN podcast_stars s
                    ON e.id = s.episode_id AND e.show_feed_url = s.show_feed_url
                WHERE e.show_feed_url = ?
                ORDER BY e.pub_date DESC
                LIMIT ?
                """, arguments: [feedURL, limit])
            return rows.compactMap { row -> PodcastEpisode? in
                let audioURLString: String = row["audio_url"]
                guard RSSPodcastParser.isHTTPURL(audioURLString),
                      let audioURL = URL(string: audioURLString) else {
                    return nil
                }
                let imageURLString: String? = row["image_url"]
                let pubDateDouble: Double? = row["pub_date"]
                let duration: Double? = row["duration"]
                let episodeNumber: Int? = row["episode_number"]
                let seasonNumber: Int? = row["season_number"]
                let episodeType: String? = row["episode_type"]
                let explicitInt: Int = row["explicit"]
                let fileSize: Int64? = row["file_size"]
                let mimeType: String? = row["mime_type"]
                let playbackPosition: Double = row["playback_position"]
                let isStarredInt: Int = row["is_starred"]
                let chaptersURLString: String? = row["chapters_url"]
                let chaptersJSON: String? = row["chapters_json"]

                var episode = PodcastEpisode(
                    id: row["id"],
                    showID: row["show_feed_url"],
                    title: row["title"],
                    description: row["description"],
                    pubDate: pubDateDouble.map { Date(timeIntervalSince1970: $0) },
                    duration: duration,
                    audioURL: audioURL,
                    imageURL: imageURLString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    episodeNumber: episodeNumber,
                    seasonNumber: seasonNumber,
                    episodeType: episodeType,
                    explicit: explicitInt == 1,
                    fileSize: fileSize,
                    mimeType: mimeType,
                    chaptersURL: chaptersURLString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    chapters: Self.decodeChapters(chaptersJSON)
                )
                episode.playbackPosition = playbackPosition
                episode.isStarred = isStarredInt == 1
                return episode
            }
        }
    }

    func upsertEpisodes(_ episodes: [PodcastEpisode]) throws {
        guard !episodes.isEmpty else { return }
        try db.write { db in
            for episode in episodes {
                try db.execute(sql: """
                    INSERT INTO podcast_episodes (id, show_feed_url, title, description, pub_date,
                                                  duration, audio_url, image_url, episode_number,
                                                  season_number, episode_type, explicit, file_size,
                                                  mime_type, chapters_url, chapters_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (id, show_feed_url) DO UPDATE SET
                        title = excluded.title,
                        description = excluded.description,
                        pub_date = excluded.pub_date,
                        duration = excluded.duration,
                        audio_url = excluded.audio_url,
                        image_url = excluded.image_url,
                        episode_number = excluded.episode_number,
                        season_number = excluded.season_number,
                        episode_type = excluded.episode_type,
                        explicit = excluded.explicit,
                        file_size = excluded.file_size,
                        mime_type = excluded.mime_type,
                        chapters_url = excluded.chapters_url,
                        chapters_json = COALESCE(excluded.chapters_json, podcast_episodes.chapters_json)
                    """, arguments: StatementArguments([
                        episode.id, episode.showID, episode.title,
                        episode.description, episode.pubDate?.timeIntervalSince1970,
                        episode.duration, episode.audioURL.absoluteString,
                        episode.imageURL?.absoluteString,
                        episode.episodeNumber, episode.seasonNumber,
                        episode.episodeType, episode.explicit ? 1 : 0,
                        episode.fileSize, episode.mimeType,
                        episode.chaptersURL?.absoluteString,
                        Self.encodeChapters(episode.chapters)
                    ]) ?? [])
            }
        }
    }

    private static func encodeChapters(_ chapters: [PodcastChapter]) -> String? {
        guard !chapters.isEmpty,
              let data = try? JSONEncoder().encode(chapters),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private static func decodeChapters(_ json: String?) -> [PodcastChapter] {
        guard let json, let data = json.data(using: .utf8),
              let chapters = try? JSONDecoder().decode([PodcastChapter].self, from: data) else {
            return []
        }
        return PodcastChapterResolver.normalize(chapters)
    }

    func updateChapters(
        episodeID: String,
        showFeedURL: String,
        chaptersURL: URL?,
        chapters: [PodcastChapter]
    ) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE podcast_episodes
                SET chapters_url = COALESCE(?, chapters_url),
                    chapters_json = ?
                WHERE id = ? AND show_feed_url = ?
                """, arguments: [
                    chaptersURL?.absoluteString,
                    Self.encodeChapters(chapters),
                    episodeID,
                    showFeedURL
                ])
        }
    }

    // MARK: - Playback Position

    func savePlaybackPosition(episodeID: String, showFeedURL: String, position: TimeInterval, completed: Bool = false) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO podcast_playback (episode_id, show_feed_url, position, last_played, completed)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (episode_id, show_feed_url) DO UPDATE SET
                    position = excluded.position,
                    last_played = excluded.last_played,
                    completed = excluded.completed
                """, arguments: [
                    episodeID, showFeedURL, position,
                    Date().timeIntervalSince1970, completed ? 1 : 0
                ])
        }
    }

    func playbackPosition(episodeID: String, showFeedURL: String) throws -> TimeInterval {
        try db.read { db in
            try Double.fetchOne(db, sql: """
                SELECT position FROM podcast_playback
                WHERE episode_id = ? AND show_feed_url = ?
                """, arguments: [episodeID, showFeedURL]) ?? 0
        }
    }

    // MARK: - In Progress Episodes

    struct InProgressEpisode: Identifiable {
        var id: String { episodeID }
        let episodeID: String
        let showFeedURL: String
        let position: TimeInterval
        let lastPlayed: Date
        let episode: PodcastEpisode
    }

    func inProgressEpisodes(limit: Int = 20) throws -> [InProgressEpisode] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.*, e.title, e.description, e.pub_date, e.duration, e.audio_url,
                       e.image_url, e.episode_number, e.season_number, e.explicit
                FROM podcast_playback p
                JOIN podcast_episodes e ON p.episode_id = e.id AND p.show_feed_url = e.show_feed_url
                WHERE p.position > 0 AND p.completed = 0
                ORDER BY p.last_played DESC
                LIMIT ?
                """, arguments: [limit])

            return rows.compactMap { row -> InProgressEpisode? in
                let audioURLString: String = row["audio_url"]
                guard RSSPodcastParser.isHTTPURL(audioURLString),
                      let audioURL = URL(string: audioURLString) else { return nil }
                let imageURLString: String? = row["image_url"]
                let pubDateDouble: Double? = row["pub_date"]
                let duration: Double? = row["duration"]
                let episodeNumber: Int? = row["episode_number"]
                let seasonNumber: Int? = row["season_number"]
                let explicitInt: Int = row["explicit"]

                let episode = PodcastEpisode(
                    id: row["episode_id"],
                    showID: row["show_feed_url"],
                    title: row["title"],
                    description: row["description"],
                    pubDate: pubDateDouble.map { Date(timeIntervalSince1970: $0) },
                    duration: duration,
                    audioURL: audioURL,
                    imageURL: imageURLString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    episodeNumber: episodeNumber,
                    seasonNumber: seasonNumber,
                    episodeType: nil,
                    explicit: explicitInt == 1,
                    fileSize: nil,
                    mimeType: nil
                )
                return InProgressEpisode(
                    episodeID: row["episode_id"],
                    showFeedURL: row["show_feed_url"],
                    position: row["position"],
                    lastPlayed: Date(timeIntervalSince1970: row["last_played"]),
                    episode: episode
                )
            }
        }
    }

    // MARK: - Stars

    func isStarred(episodeID: String, showFeedURL: String) throws -> Bool {
        try db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT 1 FROM podcast_stars
                WHERE episode_id = ? AND show_feed_url = ?
                """, arguments: [episodeID, showFeedURL]) != nil
        }
    }

    func setStarred(episodeID: String, showFeedURL: String, starred: Bool) throws {
        try db.write { db in
            if starred {
                try db.execute(sql: """
                    INSERT INTO podcast_stars (episode_id, show_feed_url, starred_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT (episode_id, show_feed_url) DO UPDATE SET
                        starred_at = excluded.starred_at
                    """, arguments: [episodeID, showFeedURL, Date().timeIntervalSince1970])
            } else {
                try db.execute(sql: """
                    DELETE FROM podcast_stars
                    WHERE episode_id = ? AND show_feed_url = ?
                    """, arguments: [episodeID, showFeedURL])
            }
        }
    }

    @discardableResult
    func toggleStarred(episodeID: String, showFeedURL: String) throws -> Bool {
        let currently = try isStarred(episodeID: episodeID, showFeedURL: showFeedURL)
        let next = !currently
        try setStarred(episodeID: episodeID, showFeedURL: showFeedURL, starred: next)
        return next
    }

    struct StarredEpisode: Identifiable {
        var id: String { "\(showFeedURL)|\(episodeID)" }
        let episodeID: String
        let showFeedURL: String
        let starredAt: Date
        let episode: PodcastEpisode
    }

    func starredEpisodes(limit: Int = 40) throws -> [StarredEpisode] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.episode_id, s.show_feed_url, s.starred_at,
                       e.title, e.description, e.pub_date, e.duration, e.audio_url,
                       e.image_url, e.episode_number, e.season_number, e.explicit,
                       COALESCE(p.position, 0) as playback_position
                FROM podcast_stars s
                JOIN podcast_episodes e
                    ON s.episode_id = e.id AND s.show_feed_url = e.show_feed_url
                LEFT JOIN podcast_playback p
                    ON s.episode_id = p.episode_id AND s.show_feed_url = p.show_feed_url
                ORDER BY s.starred_at DESC
                LIMIT ?
                """, arguments: [limit])

            return rows.compactMap { row -> StarredEpisode? in
                let audioURLString: String = row["audio_url"]
                guard RSSPodcastParser.isHTTPURL(audioURLString),
                      let audioURL = URL(string: audioURLString) else { return nil }
                let imageURLString: String? = row["image_url"]
                let pubDateDouble: Double? = row["pub_date"]
                let duration: Double? = row["duration"]
                let episodeNumber: Int? = row["episode_number"]
                let seasonNumber: Int? = row["season_number"]
                let explicitInt: Int = row["explicit"]
                let playbackPosition: Double = row["playback_position"]

                var episode = PodcastEpisode(
                    id: row["episode_id"],
                    showID: row["show_feed_url"],
                    title: row["title"],
                    description: row["description"],
                    pubDate: pubDateDouble.map { Date(timeIntervalSince1970: $0) },
                    duration: duration,
                    audioURL: audioURL,
                    imageURL: imageURLString.flatMap { RSSPodcastParser.isHTTPURL($0) ? URL(string: $0) : nil },
                    episodeNumber: episodeNumber,
                    seasonNumber: seasonNumber,
                    episodeType: nil,
                    explicit: explicitInt == 1,
                    fileSize: nil,
                    mimeType: nil
                )
                episode.playbackPosition = playbackPosition
                episode.isStarred = true

                return StarredEpisode(
                    episodeID: row["episode_id"],
                    showFeedURL: row["show_feed_url"],
                    starredAt: Date(timeIntervalSince1970: row["starred_at"]),
                    episode: episode
                )
            }
        }
    }
}
