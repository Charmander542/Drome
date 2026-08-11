import Foundation
import Combine

/// Playhead clock observed only by transport UIs (mini player / now playing).
/// Keeping this off `PlayerEngine`'s `@Published` surface stops list rows from
/// rebuilding several times a second while audio plays.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    func set(elapsed: TimeInterval, duration: TimeInterval? = nil) {
        if abs(self.elapsed - elapsed) >= 0.04 {
            self.elapsed = elapsed
        }
        if let duration, duration.isFinite, duration >= 0,
           abs(self.duration - duration) >= 0.05 {
            self.duration = duration
        }
    }

    func reset(duration: TimeInterval = 0) {
        elapsed = 0
        self.duration = max(0, duration)
    }
}
