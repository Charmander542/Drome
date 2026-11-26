import Foundation

struct LyricsDocument {
    var lines: [LRCParser.Line]
    var synced: Bool
    var source: String
    /// Extra shift applied after parse (Navidrome structured offset, duration
    /// scale residue, etc.) — informational for the UI.
    var timingOffsetMs: Int
    /// LRCLIB / sidecar duration used for scaling, when known.
    var matchedDurationSec: Int?

    init(
        lines: [LRCParser.Line],
        synced: Bool,
        source: String,
        timingOffsetMs: Int = 0,
        matchedDurationSec: Int? = nil
    ) {
        self.lines = lines
        self.synced = synced
        self.source = source
        self.timingOffsetMs = timingOffsetMs
        self.matchedDurationSec = matchedDurationSec
    }
}

/// Lyrics lookup pipeline, in priority order:
/// 1. local SQLite cache
/// 2. Navidrome `getLyricsBySongId` (serves lyrics embedded in the FLAC tags
///    or sidecar `.lrc` files next to the music)
/// 3. LRCLIB public API (matched by artist/title/duration)
///
/// Timestamps are aligned to the local file: LRC `[offset:]` tags, OpenSubsonic
/// `offset`, and mild duration scaling when the matched master is a near-cut.
actor LyricsService {
    private let database: AppDatabase
    private let client: SubsonicClient
    private let lrclib: LRCLIBClient
    private let serverKey: String

    /// Bumped when matching / alignment rules change so old hits refetch once.
    private static let lrclibSource = "lrclib.v5"
    private static let navidromeSource = "navidrome.v4"
    private static let legacySources: Set<String> = [
        "lrclib", "lrclib.v2", "lrclib.v3", "lrclib.v4",
        "navidrome", "navidrome.v2", "navidrome.v3",
    ]

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
            // Ignore pre-alignment-fix rows — they may be wrong song or unscaled.
            if Self.legacySources.contains(cached.source) {
                // Fall through to refetch.
            } else {
                return document(
                    from: cached.content,
                    synced: cached.synced,
                    source: cached.source,
                    songDuration: song.duration)
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
        // Unsynced Navidrome text used to short-circuit before LRCLIB — songs
        // with embedded plain lyrics (e.g. some Kanye tags) never got karaoke.
        // Only accept Navidrome as final when it has usable line timestamps;
        // otherwise keep plain as a fallback after trying LRCLIB synced LRC.
        var unsyncedFallback: (content: String, source: String, offsetMs: Int)?

        // 1. Navidrome (embedded tags / .lrc sidecar files, served as
        //    OpenSubsonic structured lyrics).
        if let structured = try? await client.lyrics(songId: song.id),
           let best = preferTimed(structured),
           let lines = best.line, !lines.isEmpty {
            let hasTiming = lines.contains { $0.start != nil }
            let offsetMs = best.offset ?? 0
            let content = LRCParser.serialize(
                lines: lines.map { ($0.start, $0.value) },
                offsetMs: offsetMs)
            if hasTiming {
                store(song: song, synced: true, content: content, source: Self.navidromeSource)
                return document(
                    from: content,
                    synced: true,
                    source: Self.navidromeSource,
                    songDuration: song.duration,
                    structuredOffsetMs: offsetMs)
            }
            unsyncedFallback = (content, Self.navidromeSource, offsetMs)
        }

        // 2. LRCLIB — prefer synced karaoke; plain only if we have nothing else.
        if let artist = song.artist,
           let result = try? await lrclib.lyrics(
            artist: artist, title: song.title,
            album: song.album, duration: song.duration) {
            let matchedDuration = result.duration.map { Int($0.rounded()) }
            if let lrc = result.syncedLyrics, !lrc.isEmpty {
                store(song: song, synced: true, content: lrc, source: Self.lrclibSource)
                return document(
                    from: lrc,
                    synced: true,
                    source: Self.lrclibSource,
                    songDuration: song.duration,
                    matchedDurationSec: matchedDuration)
            }
            if unsyncedFallback == nil,
               let plain = result.plainLyrics, !plain.isEmpty {
                store(song: song, synced: false, content: plain, source: Self.lrclibSource)
                return document(
                    from: plain,
                    synced: false,
                    source: Self.lrclibSource,
                    songDuration: song.duration,
                    matchedDurationSec: matchedDuration)
            }
        }

        if let fallback = unsyncedFallback {
            store(
                song: song,
                synced: false,
                content: fallback.content,
                source: fallback.source)
            return document(
                from: fallback.content,
                synced: false,
                source: fallback.source,
                songDuration: song.duration,
                structuredOffsetMs: fallback.offsetMs)
        }

        // Negative cache so the indexer and repeated plays don't refetch.
        try? database.storeLyrics(negativeEntry(for: song))
        return nil
    }

    /// Prefer entries that actually carry line start times. A `synced: true`
    /// flag with nil starts is treated as unsynced so we can still ask LRCLIB.
    private func preferTimed(_ items: [StructuredLyrics]) -> StructuredLyrics? {
        items.first(where: { $0.line?.contains(where: { $0.start != nil }) == true })
            ?? items.first(where: { $0.synced == true })
            ?? items.first
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

    private func document(
        from content: String,
        synced: Bool,
        source: String,
        songDuration: Int?,
        structuredOffsetMs: Int = 0,
        matchedDurationSec: Int? = nil
    ) -> LyricsDocument {
        // Embedded `[offset:]` is applied inside the parser. Structured offset
        // is also written into the serialized LRC when caching from Navidrome.
        var lines = LRCParser.parse(content, applyEmbeddedOffset: true)

        // Duration scale only when we know the remote master's length (LRCLIB).
        // Never invent a scale from the last lyric stamp — sidecar / embedded
        // LRC is already timed for this file and stretching it causes mid-song drift.
        if synced,
           let songDuration, songDuration > 0,
           let fromSec = matchedDurationSec, fromSec > 0 {
            lines = LRCParser.scale(
                lines,
                fromDurationMs: fromSec * 1000,
                toDurationMs: songDuration * 1000)
        }

        return LyricsDocument(
            lines: lines,
            synced: synced,
            source: source,
            timingOffsetMs: structuredOffsetMs,
            matchedDurationSec: matchedDurationSec)
    }

}
