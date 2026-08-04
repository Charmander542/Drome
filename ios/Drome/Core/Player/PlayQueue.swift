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
        case album
        case playlist(id: String)
        case artist
        case genre
        case search
        case mix
        case outOfRotation
    }

    var label: String
    var kind: Kind

    /// When the user explicitly plays the Out of Rotation playlist, its songs
    /// are obviously allowed to play (they are only excluded from algorithmic
    /// selection everywhere else).
    var allowsOutOfRotation: Bool {
        kind == .outOfRotation
    }
}

enum ShuffleMode: String {
    case off
    /// Weighted random favoring higher-rated tracks: weight ∝ (rating + 1)².
    case smart
    /// Uniform random.
    case random
}

enum RepeatMode {
    case off, all, one
}
