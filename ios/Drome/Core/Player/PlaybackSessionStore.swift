import Foundation

/// Durable snapshot of an in-progress listen so cold launch + Recently Played
/// can restore the exact queue, shuffle order, and playhead.
struct PlaybackSessionSnapshot: Codable, Equatable {
    var resumeKey: String
    var label: String
    var kindCase: String
    var kindId: String?
    var currentSong: Song
    var elapsed: TimeInterval
    var shuffleMode: String
    var repeatMode: String
    var autoplayEnabled: Bool
    var history: [Song]
    var userQueue: [Song]
    var contextQueue: [Song]
    var originalContextOrder: [Song]
    var fullContextSongs: [Song]
    var updatedAt: TimeInterval

    init(resumeKey: String,
         label: String,
         kind: PlaybackContext.Kind,
         currentSong: Song,
         elapsed: TimeInterval,
         shuffleMode: String,
         repeatMode: String,
         autoplayEnabled: Bool,
         history: [Song],
         userQueue: [Song],
         contextQueue: [Song],
         originalContextOrder: [Song],
         fullContextSongs: [Song],
         updatedAt: TimeInterval) {
        self.resumeKey = resumeKey
        self.label = label
        switch kind {
        case .album(let id):
            kindCase = "album"; kindId = id
        case .playlist(let id):
            kindCase = "playlist"; kindId = id
        case .artist(let id):
            kindCase = "artist"; kindId = id
        case .genre:
            kindCase = "genre"; kindId = nil
        case .search:
            kindCase = "search"; kindId = nil
        case .mix:
            kindCase = "mix"; kindId = nil
        case .outOfRotation:
            kindCase = "outOfRotation"; kindId = nil
        }
        self.currentSong = currentSong
        self.elapsed = elapsed
        self.shuffleMode = shuffleMode
        self.repeatMode = repeatMode
        self.autoplayEnabled = autoplayEnabled
        self.history = history
        self.userQueue = userQueue
        self.contextQueue = contextQueue
        self.originalContextOrder = originalContextOrder
        self.fullContextSongs = fullContextSongs
        self.updatedAt = updatedAt
    }

    func makeContext() -> PlaybackContext {
        let kind: PlaybackContext.Kind
        switch kindCase {
        case "album":
            kind = .album(id: kindId ?? currentSong.albumId ?? "")
        case "playlist":
            kind = .playlist(id: kindId ?? "")
        case "artist":
            kind = .artist(id: kindId ?? currentSong.artistId ?? "")
        case "genre":
            kind = .genre
        case "search":
            kind = .search
        case "outOfRotation":
            kind = .outOfRotation
        default:
            kind = .mix
        }
        return PlaybackContext(label: label, kind: kind)
    }

    /// Keep payloads small — autoplay queues grow fast and used to blow past
    /// the 4 MB CFPreferences limit when this lived in UserDefaults.
    mutating func trimForPersistence(
        maxHistory: Int = 40,
        maxUserQueue: Int = 50,
        maxContext: Int = 120,
        maxFullContext: Int = 160
    ) {
        if history.count > maxHistory {
            history = Array(history.suffix(maxHistory))
        }
        if userQueue.count > maxUserQueue {
            userQueue = Array(userQueue.prefix(maxUserQueue))
        }
        if contextQueue.count > maxContext {
            contextQueue = Array(contextQueue.prefix(maxContext))
        }
        if originalContextOrder.count > maxContext {
            originalContextOrder = Array(originalContextOrder.prefix(maxContext))
        }
        if fullContextSongs.count > maxFullContext {
            fullContextSongs = Array(fullContextSongs.prefix(maxFullContext))
        }
    }
}

/// Per-account store of recent playback sessions keyed by resume key.
///
/// On disk under Application Support — never UserDefaults. Full Infinite Shuffle
/// queues easily exceeded the 4 MB CFPreferences limit and crashed the process.
@MainActor
final class PlaybackSessionStore {
    private static let maxSessions = 12
    private static let maxFileBytes = 3_500_000

    private let defaultsKey: String
    private let fileURL: URL
    private var byKey: [String: PlaybackSessionSnapshot] = [:]
    private(set) var latestKey: String?

    init(userKey: String) {
        defaultsKey = "drome.playbackSessions.\(userKey)"
        fileURL = Self.sessionsFileURL(userKey: userKey)
        load()
    }

    func save(_ snap: PlaybackSessionSnapshot) {
        var trimmed = snap
        trimmed.trimForPersistence()
        byKey[trimmed.resumeKey] = trimmed
        latestKey = trimmed.resumeKey
        if byKey.count > Self.maxSessions {
            let ordered = byKey.values.sorted { $0.updatedAt > $1.updatedAt }
            byKey = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maxSessions).map {
                ($0.resumeKey, $0)
            })
        }
        persistAsync()
        #if os(iOS)
        let song = trimmed.currentSong
        // Off the audio/UI critical path — App Group prefs have been flaky.
        Task(priority: .utility) { @MainActor in
            MessagesShareBridge.pushRecent(
                id: song.id,
                title: song.title,
                artist: song.displayArtist,
                album: song.album ?? "",
                coverArt: song.coverArt ?? song.albumId)
        }
        #endif
    }

    func snapshot(forResumeKey key: String) -> PlaybackSessionSnapshot? {
        byKey[key]
    }

    func latest() -> PlaybackSessionSnapshot? {
        if let latestKey, let snap = byKey[latestKey] { return snap }
        return byKey.values.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func load() {
        // Prefer the known key first — avoid dictionaryRepresentation until needed.
        let legacyData = UserDefaults.standard.data(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        Self.purgeLegacyUserDefaultsSessions()

        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            applyLoaded(decoded)
            return
        }

        // One-time migration from the old UserDefaults blob (if it still decoded).
        if let legacyData,
           let decoded = try? JSONDecoder().decode(Stored.self, from: legacyData) {
            applyLoaded(decoded)
            persistAsync()
        }
    }

    /// Wipe every `drome.playbackSessions.*` key — oversized saves corrupt prefs.
    /// One-shot: full `dictionaryRepresentation()` itself can hang on a sick store.
    private static func purgeLegacyUserDefaultsSessions() {
        let flagKey = "drome.didPurgeLegacyPlaybackSessions"
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: flagKey) {
            // Still clear this account's known key if somehow recreated.
            return
        }
        let keys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("drome.playbackSessions.")
        }
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: flagKey)
    }

    private func applyLoaded(_ decoded: Stored) {
        byKey = decoded.sessions.mapValues { snap in
            var copy = snap
            copy.trimForPersistence()
            return copy
        }
        latestKey = decoded.latestKey
        if byKey.count > Self.maxSessions {
            let ordered = byKey.values.sorted { $0.updatedAt > $1.updatedAt }
            byKey = Dictionary(uniqueKeysWithValues: ordered.prefix(Self.maxSessions).map {
                ($0.resumeKey, $0)
            })
        }
    }

    private func persistAsync() {
        let stored = Stored(sessions: byKey, latestKey: latestKey)
        let url = fileURL
        let maxBytes = Self.maxFileBytes
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(stored),
                  data.count < maxBytes
            else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func sessionsFileURL(userKey: String) -> URL {
        let safe = userKey
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("Drome", isDirectory: true)
            .appendingPathComponent("playbackSessions-\(safe).json", isDirectory: false)
    }

    private struct Stored: Codable {
        var sessions: [String: PlaybackSessionSnapshot]
        var latestKey: String?
    }
}
