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
}

/// Per-account store of recent playback sessions keyed by resume key.
@MainActor
final class PlaybackSessionStore {
    private let defaultsKey: String
    private var byKey: [String: PlaybackSessionSnapshot] = [:]
    private(set) var latestKey: String?

    init(userKey: String) {
        defaultsKey = "drome.playbackSessions.\(userKey)"
        load()
    }

    func save(_ snap: PlaybackSessionSnapshot) {
        byKey[snap.resumeKey] = snap
        latestKey = snap.resumeKey
        // Cap so UserDefaults stays lean.
        if byKey.count > 40 {
            let ordered = byKey.values.sorted { $0.updatedAt > $1.updatedAt }
            byKey = Dictionary(uniqueKeysWithValues: ordered.prefix(40).map { ($0.resumeKey, $0) })
        }
        persist()
        #if os(iOS)
        let song = snap.currentSong
        MessagesShareBridge.pushRecent(
            id: song.id,
            title: song.title,
            artist: song.displayArtist,
            album: song.album ?? "",
            coverArt: song.coverArt ?? song.albumId)
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
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        byKey = decoded.sessions
        latestKey = decoded.latestKey
    }

    private func persist() {
        let stored = Stored(sessions: byKey, latestKey: latestKey)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private struct Stored: Codable {
        var sessions: [String: PlaybackSessionSnapshot]
        var latestKey: String?
    }
}
