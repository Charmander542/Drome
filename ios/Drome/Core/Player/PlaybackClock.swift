import Foundation
import Combine

/// Playhead clock observed only by transport UIs (mini player / now playing).
/// Keeping this off `PlayerEngine`'s `@Published` surface stops list rows from
/// rebuilding several times a second while audio plays.
///
/// Engine ticks still arrive ~2 Hz; `displayElapsed(at:)` interpolates between
/// anchors so scrubbers glide instead of jumping. Small AV drift is ignored so
/// re-anchors don’t yank the thumb every half-second.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    /// When true, `displayElapsed` advances with wall time from the last anchor.
    @Published private(set) var isPlaying: Bool = false

    private var anchorElapsed: TimeInterval = 0
    private var anchorAt: Date = .now

    /// AV playhead can lag/lead the interpolator by this much without a snap.
    private let softCorrectTolerance: TimeInterval = 0.45

    func set(elapsed: TimeInterval, duration: TimeInterval? = nil, playing: Bool? = nil) {
        let safeElapsed = elapsed.isFinite ? max(0, elapsed) : 0

        if let playing, playing != isPlaying {
            // Playing state change — always re-anchor from the new truth.
            anchorElapsed = safeElapsed
            anchorAt = Date()
            isPlaying = playing
        } else if isPlaying {
            let predicted = displayElapsed(at: Date())
            let drift = safeElapsed - predicted
            if abs(drift) > softCorrectTolerance {
                // Seek / stall / track change — hard snap.
                anchorElapsed = safeElapsed
                anchorAt = Date()
            }
            // else: keep wall-clock glide; ignore tiny AV jitter.
        } else {
            anchorElapsed = safeElapsed
            anchorAt = Date()
        }

        if abs(self.elapsed - safeElapsed) >= 0.04 {
            self.elapsed = safeElapsed
        }
        if let duration, duration.isFinite, duration >= 0,
           abs(self.duration - duration) >= 0.05 {
            self.duration = duration
        }
    }

    /// Pause/resume without a new AV tick — freeze or restart the interpolator.
    func setPlaying(_ playing: Bool) {
        let now = displayElapsed(at: Date())
        anchorElapsed = now
        anchorAt = Date()
        if abs(elapsed - now) >= 0.01 {
            elapsed = now
        }
        isPlaying = playing
    }

    /// Frame-smooth playhead for `TimelineView` / scrubbers.
    func displayElapsed(at date: Date = Date()) -> TimeInterval {
        let raw: TimeInterval
        if isPlaying {
            raw = anchorElapsed + date.timeIntervalSince(anchorAt)
        } else {
            raw = anchorElapsed
        }
        let capped = duration > 0 ? min(raw, duration) : raw
        guard capped.isFinite else { return 0 }
        return max(0, capped)
    }

    func reset(duration: TimeInterval = 0) {
        elapsed = 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        isPlaying = false
        anchorElapsed = 0
        anchorAt = Date()
    }
}
