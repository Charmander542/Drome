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
    static func stuckTickThreshold(bufferEmpty: Bool, waiting: Bool, playingFrozen: Bool) -> Int {
        if bufferEmpty || waiting { return 6 }      // ~3s at 0.5s cadence
        if playingFrozen { return 10 }              // ~5s
        return 8
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
}
