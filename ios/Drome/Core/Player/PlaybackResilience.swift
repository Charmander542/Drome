import Foundation

/// Pure decision helpers for stall / silence recovery.
/// Kept free of AVFoundation so we can reason about thrash loops without a device.
enum PlaybackResilience {
    /// Reasons that must pierce post-rebuild quiet periods.
    /// Note: `network-regained` is intentionally NOT hard — flaky Tailscale
    /// regain storms were burning the rebuild circuit breaker and skipping tracks.
    static func isHardFailure(_ reason: String) -> Bool {
        reason == "failedToEnd"
            || reason == "current-item-failed"
            || reason == "item-failed-waiting"
            || reason == "ready-timeout-failed"
            || reason.hasPrefix("failed")
    }

    /// Minimum acceptable on-disk MP3 cache size for a track of `duration` seconds.
    static func minimumStreamCacheBytes(durationSeconds: Int?) -> Int {
        guard let duration = durationSeconds, duration > 15 else { return 48_000 }
        let eighth = (duration * 128_000 / 8) / 8
        return max(48_000, min(eighth, 400_000))
    }

    /// Whether a playhead sample counts as forward progress.
    static func playheadAdvanced(
        previous: TimeInterval,
        next: TimeInterval,
        minimumDelta: TimeInterval = 0.3
    ) -> Bool {
        next >= previous + minimumDelta
    }

    /// Tick threshold before declaring playback stuck.
    /// Empty/waiting recovers sooner; playing-but-frozen (BT silence) waits longer.
    /// `pausedWhileWanting` is the "UI says play, AVPlayer is paused" dead state.
    static func stuckTickThreshold(
        bufferEmpty: Bool,
        waiting: Bool,
        playingFrozen: Bool,
        pausedWhileWanting: Bool = false
    ) -> Int {
        if pausedWhileWanting { return 4 }          // ~2s — kick play() soon
        if bufferEmpty || waiting { return 6 }      // ~3s at 0.5s cadence
        if playingFrozen { return 10 }              // ~5s
        return 8
    }

    /// True when intent says play but the transport is fully stopped.
    static func isPausedWhileWanting(wantsToPlay: Bool, isPaused: Bool, rate: Double) -> Bool {
        wantsToPlay && isPaused && rate < 0.01
    }

    /// Max resilient rebuilds for one track before skipping.
    static let maxRebuildsPerTrack = 3

    /// Whether the Nth rebuild should invalidate the on-disk stream cache.
    /// Invalidate from attempt 1 — mid-size truncated files passed the byte
    /// floor and got reused once, wasting a rebuild before the old >=2 rule.
    static func shouldInvalidateCache(rebuildAttempt: Int) -> Bool {
        rebuildAttempt >= 1
    }

    /// Soft-seek allowed only on the first stall of a fresh track.
    static func canSoftSeek(
        softSeekCount: Int,
        rebuildCount: Int,
        reason: String,
        hasCachedFile: Bool
    ) -> Bool {
        softSeekCount < 1
            && rebuildCount == 0
            && !hasCachedFile
            && !isHardFailure(reason)
    }

    /// Prefer the published playhead when AV reports ~0 mid-track (stalled /
    /// rebuilt items often reset `currentTime` before a deferred seek lands).
    static func recoveryElapsed(accurate: TimeInterval, published: TimeInterval) -> TimeInterval {
        if accurate < 0.75, published > 2.0 { return published }
        return max(0, max(accurate, published))
    }

    /// Late-track stalls should advance, not soft-seek/rebuild back into the song.
    static func shouldAdvanceNearEnd(
        position: TimeInterval,
        duration: TimeInterval,
        threshold: TimeInterval = 2.5
    ) -> Bool {
        duration > 8 && position >= max(0, duration - threshold)
    }

    /// Whether a seekable window is far enough along to honor a recovery seek
    /// without clamping the target down to a few buffered seconds.
    static func seekableCovers(
        target: TimeInterval,
        seekableEnd: TimeInterval?,
        tolerance: TimeInterval = 1.5
    ) -> Bool {
        guard let end = seekableEnd, end.isFinite, end > 0 else { return false }
        return end + tolerance >= target
    }
}
