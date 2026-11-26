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
/// 3. LRCLIB public API (matched by artist/title/duration; prefers word-synced)
///
/// Results stay in a small **session** memory cache only — nothing is written to
/// phone SQLite. Backend sidecars + Navidrome are the durable store.
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

    private enum MemoryEntry {
        case hit(LyricsDocument)
        case miss
    }

    /// Soft cap so flipping through many songs doesn't retain every LRC blob.
    private static let memoryCap = 48
    private var memory: [String: MemoryEntry] = [:]
    private var memoryOrder: [String] = []

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
        // Reclaim older on-disk lyrics / FTS rows for this server.
        try? database.clearLyrics(serverKey: serverKey)
    }

    func lyrics(for song: Song, allowNetwork: Bool = true) async -> LyricsDocument? {
        if let entry = memory[song.id] {
            switch entry {
            case .hit(let document): return document
            case .miss: return nil
            }
        }
        guard allowNetwork else { return nil }
        let fresh = await fetch(song: song)
        remember(songId: song.id, document: fresh)
        return fresh
    }

    /// True if this session already resolved lyrics (hit or miss) for the song.
    func isCached(_ song: Song) -> Bool {
        memory[song.id] != nil
    }

    /// Drops the session entry and refetches (for a "reload lyrics" affordance).
    func refetch(for song: Song) async -> LyricsDocument? {
        forget(songId: song.id)
        let fresh = await fetch(song: song)
        remember(songId: song.id, document: fresh)
        return fresh
    }

    private func fetch(song: Song) async -> LyricsDocument? {
        // Unsynced Navidrome text used to short-circuit before LRCLIB — songs
        // with embedded plain lyrics (e.g. some Kanye tags) never got karaoke.
        // Only accept Navidrome as final when it has usable line timestamps;
        // otherwise keep plain as a fallback after trying LRCLIB synced LRC.
        var unsyncedFallback: (content: String, source: String, offsetMs: Int)?

        // 1. Companion raw sidecar — preserves Enhanced LRC word stamps.
        if let wishlist,
           let sidecar = try? await wishlist.trackLyrics(
            title: song.title, artist: song.artist ?? ""),
           sidecar.found,
           let content = sidecar.content, !content.isEmpty {
            let synced = sidecar.synced || LRCParser.isSynced(content)
            return document(
                from: content,
                synced: synced,
                source: Self.sidecarSource,
                songDuration: song.duration)
        }

        // 2. Navidrome structured lyrics — prefer timed; defer plain to after LRCLIB.
        if let structured = try? await client.lyrics(songId: song.id),
           let best = preferTimed(structured),
           let lines = best.line, !lines.isEmpty {
            let hasTiming = lines.contains { $0.start != nil }
            let offsetMs = best.offset ?? 0
            let content = LRCParser.serialize(
                lines: lines.map { ($0.start, $0.value) },
                offsetMs: offsetMs)
            if hasTiming {
                return document(
                    from: content,
                    synced: true,
                    source: Self.navidromeSource,
                    songDuration: song.duration,
                    structuredOffsetMs: offsetMs)
            }
            unsyncedFallback = (content, Self.navidromeSource, offsetMs)
        }

        // 3. LRCLIB — prefer synced karaoke; plain only if we have nothing else.
        if let artist = song.artist,
           let result = try? await lrclib.lyrics(
            artist: artist, title: song.title,
            album: song.album, duration: song.duration) {
            let matchedDuration = result.duration.map { Int($0.rounded()) }
            if let lrc = result.syncedLyrics, !lrc.isEmpty {
                return document(
                    from: lrc,
                    synced: true,
                    source: Self.lrclibSource,
                    songDuration: song.duration,
                    matchedDurationSec: matchedDuration)
            }
            if unsyncedFallback == nil,
               let plain = result.plainLyrics, !plain.isEmpty {
                return document(
                    from: plain,
                    synced: false,
                    source: Self.lrclibSource,
                    songDuration: song.duration,
                    matchedDurationSec: matchedDuration)
            }
        }

        if let fallback = unsyncedFallback {
            return document(
                from: fallback.content,
                synced: false,
                source: fallback.source,
                songDuration: song.duration,
                structuredOffsetMs: fallback.offsetMs)
        }

        return nil
    }

    /// Prefer entries that actually carry line start times. A `synced: true`
    /// flag with nil starts is treated as unsynced so we can still ask LRCLIB.
    private func preferTimed(_ items: [StructuredLyrics]) -> StructuredLyrics? {
        items.first(where: { $0.line?.contains(where: { $0.start != nil }) == true })
            ?? items.first(where: { $0.synced == true })
            ?? items.first
    }

    private func remember(songId: String, document: LyricsDocument?) {
        if memory[songId] == nil {
            memoryOrder.append(songId)
        }
        memory[songId] = document.map { .hit($0) } ?? .miss
        while memoryOrder.count > Self.memoryCap {
            let evicted = memoryOrder.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func forget(songId: String) {
        memory.removeValue(forKey: songId)
        memoryOrder.removeAll { $0 == songId }
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
