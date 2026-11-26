import Foundation

enum LyricsWordTiming: String, Equatable {
    /// Enhanced LRC / measured word stamps from the file.
    case measured
    /// Line-synced LRC with paced word starts.
    case approximated
    /// Plain text or no usable timing.
    case none
}

struct LyricsDocument {
    var lines: [LRCParser.Line]
    var synced: Bool
    var source: String
    /// Extra shift applied after parse (Navidrome structured offset, duration
    /// scale residue, etc.) — informational for the UI.
    var timingOffsetMs: Int
    /// LRCLIB / sidecar duration used for scaling, when known.
    var matchedDurationSec: Int?
    /// Whether karaoke uses real word stamps or paced approximations.
    var wordTiming: LyricsWordTiming

    init(
        lines: [LRCParser.Line],
        synced: Bool,
        source: String,
        timingOffsetMs: Int = 0,
        matchedDurationSec: Int? = nil,
        wordTiming: LyricsWordTiming? = nil
    ) {
        self.lines = lines
        self.synced = synced
        self.source = source
        self.timingOffsetMs = timingOffsetMs
        self.matchedDurationSec = matchedDurationSec
        if let wordTiming {
            self.wordTiming = wordTiming
        } else if !synced {
            self.wordTiming = .none
        } else if lines.contains(where: { $0.words.contains(where: \.measured) }) {
            self.wordTiming = .measured
        } else {
            self.wordTiming = .approximated
        }
    }
}

/// Lyrics lookup pipeline, in priority order:
/// 1. Companion library sidecar (raw `.lrc` next to the file — keeps word stamps)
/// 2. Navidrome `getLyricsBySongId` when it has usable line timing
/// 3. local SQLite cache (offline / after network miss)
/// 4. LRCLIB public API (matched by artist/title/duration; prefers word-synced)
///
/// Timestamps are aligned to the local file: LRC `[offset:]` tags, OpenSubsonic
/// `offset`, and mild duration scaling when the matched master is a near-cut.
actor LyricsService {
    private let database: AppDatabase
    private let client: SubsonicClient
    private let lrclib: LRCLIBClient
    private let wishlist: DromeWishlistClient?
    private let serverKey: String

    /// Bumped when matching / alignment rules change so old hits refetch once.
    private static let lrclibSource = "lrclib.v5"
    private static let navidromeSource = "navidrome.v5"
    private static let sidecarSource = "sidecar.v1"
    private static let legacySources: Set<String> = [
        "lrclib", "lrclib.v2", "lrclib.v3", "lrclib.v4",
        "navidrome", "navidrome.v2", "navidrome.v3", "navidrome.v4",
    ]

    init(
        database: AppDatabase,
        client: SubsonicClient,
        serverKey: String,
        wishlist: DromeWishlistClient? = nil
    ) {
        self.database = database
        self.client = client
        self.lrclib = LRCLIBClient(session: client.session)
        self.wishlist = wishlist
        self.serverKey = serverKey
    }

    func lyrics(for song: Song, allowNetwork: Bool = true) async -> LyricsDocument? {
        if allowNetwork, let fresh = await fetchAndCache(song: song) {
            return fresh
        }

        if let cached = try? database.cachedLyrics(serverKey: serverKey, songId: song.id) {
            if cached.source == "none" {
                return nil
            }
            if Self.legacySources.contains(cached.source) {
                guard allowNetwork else { return nil }
                return await fetchAndCache(song: song)
            }
            return document(
                from: cached.content,
                synced: cached.synced,
                source: cached.source,
                songDuration: song.duration)
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
        // 1. Companion raw sidecar — preserves Enhanced LRC word stamps.
        if let wishlist,
           let sidecar = try? await wishlist.trackLyrics(
            title: song.title, artist: song.artist ?? ""),
           sidecar.found,
           let content = sidecar.content, !content.isEmpty {
            let synced = sidecar.synced || LRCParser.isSynced(content)
            store(song: song, synced: synced, content: content, source: Self.sidecarSource)
            return document(
                from: content,
                synced: synced,
                source: Self.sidecarSource,
                songDuration: song.duration)
        }

        // 2. Navidrome structured lyrics — only when timestamps exist.
        if let structured = try? await client.lyrics(songId: song.id),
           let best = preferTimed(structured),
           let lines = best.line, !lines.isEmpty,
           lines.contains(where: { $0.start != nil }) {
            let offsetMs = best.offset ?? 0
            let content = LRCParser.serialize(
                lines: lines.map { ($0.start, $0.value) },
                offsetMs: offsetMs)
            store(song: song, synced: true, content: content, source: Self.navidromeSource)
            return document(
                from: content,
                synced: true,
                source: Self.navidromeSource,
                songDuration: song.duration,
                structuredOffsetMs: offsetMs)
        }

        // 3. Warm cache after a network miss on server sources.
        if let cached = try? database.cachedLyrics(serverKey: serverKey, songId: song.id),
           cached.source != "none",
           !Self.legacySources.contains(cached.source) {
            return document(
                from: cached.content,
                synced: cached.synced,
                source: cached.source,
                songDuration: song.duration)
        }

        // 4. LRCLIB fallback (prefers word-synced among candidates).
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
            if let plain = result.plainLyrics, !plain.isEmpty {
                store(song: song, synced: false, content: plain, source: Self.lrclibSource)
                return document(
                    from: plain,
                    synced: false,
                    source: Self.lrclibSource,
                    songDuration: song.duration,
                    matchedDurationSec: matchedDuration)
            }
        }

        // Negative cache so the indexer and repeated plays don't refetch.
        try? database.storeLyrics(negativeEntry(for: song))
        return nil
    }

    /// Prefer entries that actually carry line start times.
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
