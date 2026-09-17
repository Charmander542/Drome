import Foundation

/// A song instance in the queue. Wrapped with a unique id so the same track
/// can appear multiple times and rows stay stable while reordering.
struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let song: Song
    var isAutoplay: Bool

    init(song: Song, isAutoplay: Bool = false) {
        self.id = UUID()
        self.song = song
        self.isAutoplay = isAutoplay
    }
}

/// What the current queue was built from — shown as "Next from: …" in the
/// queue screen, and used to decide shuffle-exclusion semantics.
struct PlaybackContext: Equatable {
    enum Kind: Equatable {
        case album(id: String)
        case playlist(id: String)
        case artist(id: String)
        case genre
        case search
        case mix
        case outOfRotation
        case podcast(showID: String)
    }

    var label: String
    var kind: Kind

    /// When the user explicitly plays the Out of Rotation playlist, its songs
    /// are obviously allowed to play (they are only excluded from algorithmic
    /// selection everywhere else).
    var allowsOutOfRotation: Bool {
        kind == .outOfRotation
    }

    /// Stable key used to resume a listening session from Recently Played.
    func resumeKey(fallbackSong: Song? = nil) -> String {
        switch kind {
        case .album(let id):
            return "album:\(id)"
        case .playlist(let id):
            return "playlist:\(id)"
        case .artist(let id):
            return "artist:\(id)"
        case .genre:
            return "genre:\(label)"
        case .mix:
            return "mix:\(label)"
        case .outOfRotation:
            return "outOfRotation"
        case .search:
            if let id = fallbackSong?.id { return "song:\(id)" }
            return "search:\(label)"
        case .podcast(let showID):
            return "podcast:\(showID)"
        }
    }
}

enum ShuffleMode: String {
    case off
    /// Weighted random favoring higher-rated tracks: weight ∝ (rating + 1)².
    case smart
    /// Uniform random.
    case random

    var userLabel: String {
        switch self {
        case .off: return "In order"
        case .smart: return "Smart shuffle"
        case .random: return "Shuffle"
        }
    }

    var userHint: String {
        switch self {
        case .off: return "Plays the queue in list order"
        case .smart: return "Shuffles the queue, favoring higher-rated tracks"
        case .random: return "Shuffles the queue randomly"
        }
    }
}

enum RepeatMode {
    case off, all, one
}

enum AutoplayMode {
    static let label = "Keep playing"
    static let hint = "Adds similar songs when the queue runs out"
}
