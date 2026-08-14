import Foundation

struct LyricsDocument {
    var lines: [LRCParser.Line]
    var synced: Bool
    var source: String
}

/// Lyrics lookup pipeline, in priority order:
/// 1. local SQLite cache
/// 2. Navidrome `getLyricsBySongId` (serves lyrics embedded in the FLAC tags
///    or sidecar `.lrc` files next to the music)
/// 3. LRCLIB public API (matched by artist/title/duration)
///
/// Every network result — including "nothing found" — is cached, and synced
/// hits are added to the FTS index for deep search.
actor LyricsService {
    private let database: AppDatabase
    private let client: SubsonicClient
    private let lrclib: LRCLIBClient
    private let serverKey: String

    /// Bumped when LRCLIB matching rules change so old fuzzy hits
    /// (e.g. short titles like "2007") are refetched once.
    private static let lrclibSource = "lrclib.v2"
    private static let legacyLRCLIBSources: Set<String> = ["lrclib"]

    init(database: AppDatabase, client: SubsonicClient, serverKey: String) {
        self.database = database
        self.client = client
        self.lrclib = LRCLIBClient(session: client.session)
        self.serverKey = serverKey
    }

    func lyrics(for song: Song, allowNetwork: Bool = true) async -> LyricsDocument? {
        if let cached = try? database.cachedLyrics(serverKey: serverKey, songId: song.id) {
            if cached.source == "none" {
                return nil
            }
            // Ignore pre-match-fix LRCLIB rows — they may be the wrong song.
            if Self.legacyLRCLIBSources.contains(cached.source) {
                // Fall through to refetch.
            } else {
                return document(from: cached.content, synced: cached.synced, source: cached.source)
            }
        }
        guard allowNetwork else { return nil }
        return await fetchAndCache(song: song)
    }

    /// True if the song already has any cache entry (found or negative).
    func isCached(_ song: Song) -> Bool {
        (try? database.cachedLyrics(serverKey: serverKey, songId: song.id)) != nil
    }

    /// Drops the cache entry and refetches (for a "reload lyrics" affordance).
    func refetch(for song: Song) async -> LyricsDocument? {
        try? database.storeLyrics(negativeEntry(for: song))
        return await fetchAndCache(song: song)
    }

    private func fetchAndCache(song: Song) async -> LyricsDocument? {
        // 1. Navidrome (embedded tags / .lrc sidecar files, served as
        //    OpenSubsonic structured lyrics).
        if let structured = try? await client.lyrics(songId: song.id),
           let best = structured.first(where: { $0.synced == true }) ?? structured.first,
           let lines = best.line, !lines.isEmpty {
            let synced = (best.synced ?? false) || lines.contains { $0.start != nil }
            let content = LRCParser.serialize(lines: lines.map { ($0.start, $0.value) })
            store(song: song, synced: synced, content: content, source: "navidrome")
            return document(from: content, synced: synced, source: "navidrome")
        }

        // 2. LRCLIB fallback.
        if let artist = song.artist,
           let result = try? await lrclib.lyrics(artist: artist, title: song.title,
                                                 album: song.album, duration: song.duration) {
            if let lrc = result.syncedLyrics, !lrc.isEmpty {
                store(song: song, synced: true, content: lrc, source: Self.lrclibSource)
                return document(from: lrc, synced: true, source: Self.lrclibSource)
            }
            if let plain = result.plainLyrics, !plain.isEmpty {
                store(song: song, synced: false, content: plain, source: Self.lrclibSource)
                return document(from: plain, synced: false, source: Self.lrclibSource)
            }
        }

        // Negative cache so the indexer and repeated plays don't refetch.
        try? database.storeLyrics(negativeEntry(for: song))
        return nil
    }

    private func store(song: Song, synced: Bool, content: String, source: String) {
        try? database.storeLyrics(CachedLyrics(
            serverKey: serverKey, songId: song.id, title: song.title,
            artist: song.artist ?? "", album: song.album ?? "",
            synced: synced, content: content, source: source))
    }

    private func negativeEntry(for song: Song) -> CachedLyrics {
        CachedLyrics(serverKey: serverKey, songId: song.id, title: song.title,
                     artist: song.artist ?? "", album: song.album ?? "",
                     synced: false, content: "", source: "none")
    }

    private func document(from content: String, synced: Bool, source: String) -> LyricsDocument {
        LyricsDocument(lines: LRCParser.parse(content), synced: synced, source: source)
    }
}
