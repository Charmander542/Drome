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
/// 4. LRCLIB public API (matched by artist/title/duration; prefers word-synced
///    `lyricsfile` → Enhanced LRC)
///
/// Line-only sidecar / Navidrome hits do **not** short-circuit when online —
/// LRCLIB Word Synced can still upgrade them to measured word karaoke.
/// Network hits stay in a small **session** memory cache — SQLite is not used.
/// The current song and the next one are fetched in full as soon as playback
/// reaches them, parsed locally, then dropped about 90s after they leave the
/// playhead. Offline downloads keep their own `.lrc` next to the audio file.
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

    /// Soft cap. Playback only needs the current song, the next one, and a
    /// couple just left — the rest expire.
    private static let memoryCap = 8
    /// How long a song that is no longer current or up next keeps its sheet.
    private static let staleAfter: TimeInterval = 90
    private var memory: [String: MemoryEntry] = [:]
    private var memoryOrder: [String] = []
    private var touched: [String: Date] = [:]
    /// Current song and the immediate next one. Never expired while pinned.
    private var pinned: Set<String> = []
    private var epochs: [String: Int] = [:]
    private var inflight: [String: (epoch: Int, task: Task<LyricsDocument?, Never>)] = [:]
    private var expiryTask: Task<Void, Never>?

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

        let epoch = epochs[song.id, default: 0]
        if let running = inflight[song.id], running.epoch == epoch {
            return await running.task.value
        }
        let task = Task { await self.resolve(song: song, allowNetwork: allowNetwork, epoch: epoch) }
        inflight[song.id] = (epoch, task)
        let document = await task.value
        if inflight[song.id]?.epoch == epoch {
            inflight[song.id] = nil
        }
        return document
    }

    /// Fetch and parse the whole sheet for the song that just started, and the
    /// next one, so Now Playing reads a local document. Unpinned sheets expire
    /// `staleAfter` later.
    func noteNowPlaying(current: Song, upcoming: Song?) async {
        let now = Date()
        var pins: Set<String> = [current.id]
        if let upcoming, upcoming.id != current.id {
            pins.insert(upcoming.id)
        }
        for id in pinned where !pins.contains(id) {
            touched[id] = now
        }
        pinned = pins
        _ = await lyrics(for: current)
        if let upcoming, upcoming.id != current.id {
            _ = await lyrics(for: upcoming)
        }
        let fresh = Date()
        for id in pins {
            touched[id] = fresh
        }
        sweepExpired()
        armExpiry()
    }

    private func resolve(song: Song, allowNetwork: Bool, epoch: Int) async -> LyricsDocument? {
        if epochs[song.id, default: 0] != epoch { return nil }

        var lineOnlyOffline: LyricsDocument?
        if let offline = loadOffline(song: song) {
            // Keep measured offline karaoke. Line-only offline can still upgrade
            // via network when Word Synced lyricsfile is available.
            if offline.wordTiming == .measured || !allowNetwork {
                guard epochs[song.id, default: 0] == epoch else { return nil }
                remember(songId: song.id, document: offline)
                return offline
            }
            lineOnlyOffline = offline
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
        guard epochs[song.id, default: 0] == epoch else { return nil }
        // A failed upgrade must not throw away a line-synced sheet already on disk.
        if fresh == nil, let lineOnlyOffline {
            remember(songId: song.id, document: lineOnlyOffline)
            return lineOnlyOffline
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
        epochs[song.id, default: 0] += 1
        forget(songId: song.id)
        return await lyrics(for: song, allowNetwork: true)
    }

    /// Fetches lyrics (sidecar → Navidrome → LRCLIB) and writes raw LRC to `url`
    /// for offline Now Playing. Returns false when nothing usable was found.
    @discardableResult
    func persistOfflineLyrics(for song: Song, to url: URL) async -> Bool {
        if let existing = try? String(contentsOf: url, encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           LRCLIBClient.hasWordSync(existing) {
            // Measured word karaoke already on disk.
            return true
        }
        guard let payload = await fetch(song: song) else {
            // Keep a previously written line-only file if fetch fails.
            if let existing = try? String(contentsOf: url, encoding: .utf8),
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return false
        }
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
        // Line-synced sidecar / Navidrome also used to win before LRCLIB, which
        // blocked Word Synced `lyricsfile` upgrades — keep those as fallbacks.
        var unsyncedFallback: FetchedLyrics?
        var lineSyncedFallback: FetchedLyrics?

        // 1. Companion raw sidecar — accept immediately when it already has
        // Enhanced LRC word stamps; otherwise keep for after LRCLIB.
        if let wishlist,
           let sidecar = try? await wishlist.trackLyrics(
            title: song.title, artist: song.artist ?? ""),
           sidecar.found,
           let content = sidecar.content, !content.isEmpty {
            let synced = sidecar.synced || LRCParser.isSynced(content)
            if synced, LRCLIBClient.hasWordSync(content) {
                return FetchedLyrics(content: content, synced: true, source: Self.sidecarSource)
            }
            if synced {
                lineSyncedFallback = FetchedLyrics(
                    content: content, synced: true, source: Self.sidecarSource)
            } else {
                unsyncedFallback = FetchedLyrics(
                    content: content, synced: false, source: Self.sidecarSource)
            }
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
                // Structured lyrics are line-level — keep as fallback so LRCLIB
                // Word Synced can still upgrade to measured word karaoke.
                if lineSyncedFallback == nil {
                    lineSyncedFallback = FetchedLyrics(
                        content: content,
                        synced: true,
                        source: Self.navidromeSource,
                        structuredOffsetMs: offsetMs)
                }
            } else if unsyncedFallback == nil {
                unsyncedFallback = FetchedLyrics(
                    content: content,
                    synced: false,
                    source: Self.navidromeSource,
                    structuredOffsetMs: offsetMs)
            }
        }

        // 3. LRCLIB — Word Synced lyricsfile (as Enhanced LRC) wins; else line LRC.
        if let artist = song.artist,
           let result = try? await lrclib.lyrics(
            artist: artist, title: song.title,
            album: song.album, duration: song.duration) {
            let matchedDuration = result.duration.map { Int($0.rounded()) }
            if let lrc = result.syncedLyrics, !lrc.isEmpty {
                if LRCLIBClient.hasWordSync(lrc) || lineSyncedFallback == nil {
                    return FetchedLyrics(
                        content: lrc,
                        synced: true,
                        source: Self.lrclibSource,
                        matchedDurationSec: matchedDuration)
                }
            }
            if unsyncedFallback == nil,
               let plain = result.plainLyrics, !plain.isEmpty {
                unsyncedFallback = FetchedLyrics(
                    content: plain,
                    synced: false,
                    source: Self.lrclibSource,
                    matchedDurationSec: matchedDuration)
            }
        }

        return lineSyncedFallback ?? unsyncedFallback
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
        touched[songId] = Date()
        while memoryOrder.count > Self.memoryCap {
            guard let idx = memoryOrder.firstIndex(where: { !pinned.contains($0) }) else { break }
            let evicted = memoryOrder.remove(at: idx)
            memory.removeValue(forKey: evicted)
            touched.removeValue(forKey: evicted)
        }
    }

    private func forget(songId: String) {
        memory.removeValue(forKey: songId)
        memoryOrder.removeAll { $0 == songId }
        touched.removeValue(forKey: songId)
    }

    private func sweepExpired() {
        let now = Date()
        let stale = memory.keys.filter { id in
            !pinned.contains(id)
                && now.timeIntervalSince(touched[id] ?? .distantPast) >= Self.staleAfter
        }
        for id in stale {
            forget(songId: id)
        }
    }

    private func armExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.staleAfter * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.sweepExpired()
        }
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
        //
        // After scaling, record the timebase stamps now live on (`songDuration`)
        // so LyricsView’s playhead realign applies a *delta* scale instead of
        // stretching from the LRCLIB master a second time (mid-song drift).
        var alignedDurationSec = matchedDurationSec
        if synced,
           let songDuration, songDuration > 0,
           let fromSec = matchedDurationSec, fromSec > 0 {
            let scaled = LRCParser.scale(
                lines,
                fromDurationMs: fromSec * 1000,
                toDurationMs: songDuration * 1000)
            if scaled.map(\.startMs) != lines.map(\.startMs) {
                lines = scaled
                alignedDurationSec = songDuration
            }
        }

        return LyricsDocument(
            lines: lines,
            synced: synced,
            source: source,
            timingOffsetMs: structuredOffsetMs,
            matchedDurationSec: alignedDurationSec)
    }
}
