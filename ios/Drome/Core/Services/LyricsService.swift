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
/// 1. Offline download companion `.lrc` (written when a track is downloaded)
/// 2. Companion library sidecar (raw `.lrc` next to the file — keeps word stamps)
/// 3. Navidrome `getLyricsBySongId` when it has usable line timing
/// 4. LRCLIB public API (matched by artist/title/duration; prefers word-synced)
///
/// Network hits stay in a small **session** memory cache — SQLite is not used.
/// Offline downloads keep their own `.lrc` next to the audio file.
///
/// Timestamps are aligned to the local file: LRC `[offset:]` tags, OpenSubsonic
/// `offset`, and mild duration scaling when the matched master is a near-cut.
actor LyricsService {
    private let database: AppDatabase
    private let client: SubsonicClient
    private let lrclib: LRCLIBClient
    private let wishlist: DromeWishlistClient?
    private let serverKey: String
    /// Resolves a local offline `.lrc` path for a song id (DownloadManager).
    private let offlineLyricsURL: (@Sendable (String) -> URL?)?

    /// Bumped when matching / alignment rules change so old hits refetch once.
    private static let lrclibSource = "lrclib.v5"
    private static let navidromeSource = "navidrome.v5"
    private static let sidecarSource = "sidecar.v1"
    static let offlineSource = "offline.v1"

    private struct FetchedLyrics {
        var content: String
        var synced: Bool
        var source: String
        var structuredOffsetMs: Int = 0
        var matchedDurationSec: Int? = nil
    }

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
        wishlist: DromeWishlistClient? = nil,
        offlineLyricsURL: (@Sendable (String) -> URL?)? = nil
    ) {
        self.database = database
        self.client = client
        self.lrclib = LRCLIBClient(session: client.session)
        self.wishlist = wishlist
        self.serverKey = serverKey
        self.offlineLyricsURL = offlineLyricsURL
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

        if let offline = loadOffline(song: song) {
            remember(songId: song.id, document: offline)
            return offline
        }

        guard allowNetwork else { return nil }
        let fresh = await fetch(song: song).map { payload in
            document(
                from: payload.content,
                synced: payload.synced,
                source: payload.source,
                songDuration: song.duration,
                structuredOffsetMs: payload.structuredOffsetMs,
                matchedDurationSec: payload.matchedDurationSec)
        }
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
        return await lyrics(for: song, allowNetwork: true)
    }

    /// Fetches lyrics (sidecar → Navidrome → LRCLIB) and writes raw LRC to `url`
    /// for offline Now Playing. Returns false when nothing usable was found.
    @discardableResult
    func persistOfflineLyrics(for song: Song, to url: URL) async -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let payload = await fetch(song: song) else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try payload.content.write(to: url, atomically: true, encoding: .utf8)
            forget(songId: song.id)
            return true
        } catch {
            return false
        }
    }

    private func loadOffline(song: Song) -> LyricsDocument? {
        guard let url = offlineLyricsURL?(song.id),
              let content = try? String(contentsOf: url, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let synced = LRCParser.isSynced(content)
        return document(
            from: content,
            synced: synced,
            source: Self.offlineSource,
            songDuration: song.duration)
    }

    private func fetch(song: Song) async -> FetchedLyrics? {
        // Unsynced Navidrome text used to short-circuit before LRCLIB — songs
        // with embedded plain lyrics (e.g. some Kanye tags) never got karaoke.
        // Only accept Navidrome as final when it has usable line timestamps;
        // otherwise keep plain as a fallback after trying LRCLIB synced LRC.
        var unsyncedFallback: FetchedLyrics?

        // 1. Companion raw sidecar — preserves Enhanced LRC word stamps.
        if let wishlist,
           let sidecar = try? await wishlist.trackLyrics(
            title: song.title, artist: song.artist ?? ""),
           sidecar.found,
           let content = sidecar.content, !content.isEmpty {
            let synced = sidecar.synced || LRCParser.isSynced(content)
            return FetchedLyrics(content: content, synced: synced, source: Self.sidecarSource)
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
                return FetchedLyrics(
                    content: content,
                    synced: true,
                    source: Self.navidromeSource,
                    structuredOffsetMs: offsetMs)
            }
            unsyncedFallback = FetchedLyrics(
                content: content,
                synced: false,
                source: Self.navidromeSource,
                structuredOffsetMs: offsetMs)
        }

        // 3. LRCLIB — prefer synced karaoke; plain only if we have nothing else.
        if let artist = song.artist,
           let result = try? await lrclib.lyrics(
            artist: artist, title: song.title,
            album: song.album, duration: song.duration) {
            let matchedDuration = result.duration.map { Int($0.rounded()) }
            if let lrc = result.syncedLyrics, !lrc.isEmpty {
                return FetchedLyrics(
                    content: lrc,
                    synced: true,
                    source: Self.lrclibSource,
                    matchedDurationSec: matchedDuration)
            }
            if unsyncedFallback == nil,
               let plain = result.plainLyrics, !plain.isEmpty {
                return FetchedLyrics(
                    content: plain,
                    synced: false,
                    source: Self.lrclibSource,
                    matchedDurationSec: matchedDuration)
            }
        }

        return unsyncedFallback
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
