#!/usr/bin/env swift
import Foundation

// Mirror of PlaybackResilience — keep in sync when changing policy.
// Run: swift ios/scripts/test-playback-resilience.swift

enum PlaybackResilience {
    static func isHardFailure(_ reason: String) -> Bool {
        reason == "failedToEnd"
            || reason == "current-item-failed"
            || reason == "item-failed-waiting"
            || reason == "ready-timeout-failed"
            || reason.hasPrefix("failed")
    }

    static func minimumStreamCacheBytes(durationSeconds: Int?) -> Int {
        guard let duration = durationSeconds, duration > 15 else { return 48_000 }
        let eighth = (duration * 128_000 / 8) / 8
        return max(48_000, min(eighth, 400_000))
    }

    static func playheadAdvanced(
        previous: TimeInterval,
        next: TimeInterval,
        minimumDelta: TimeInterval = 0.3
    ) -> Bool {
        next >= previous + minimumDelta
    }

    static func stuckTickThreshold(
        bufferEmpty: Bool,
        waiting: Bool,
        playingFrozen: Bool,
        pausedWhileWanting: Bool = false
    ) -> Int {
        if pausedWhileWanting { return 4 }
        if bufferEmpty || waiting { return 6 }
        if playingFrozen { return 10 }
        return 8
    }

    static func isPausedWhileWanting(wantsToPlay: Bool, isPaused: Bool, rate: Double) -> Bool {
        wantsToPlay && isPaused && rate < 0.01
    }

    static let maxRebuildsPerTrack = 3

    static func shouldInvalidateCache(rebuildAttempt: Int) -> Bool {
        rebuildAttempt >= 1
    }

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

var failures = 0
func expect(_ cond: Bool, _ message: String) {
    if cond {
        print("PASS  \(message)")
    } else {
        failures += 1
        print("FAIL  \(message)")
    }
}

// --- Simulated scenarios ---

print("=== keepUp flicker must NOT look like hard failure ===")
expect(!PlaybackResilience.isHardFailure("silent-buffer"), "silent-buffer is soft")
expect(!PlaybackResilience.isHardFailure("waiting"), "waiting is soft")
expect(PlaybackResilience.isHardFailure("failedToEnd"), "failedToEnd is hard")
expect(!PlaybackResilience.isHardFailure("network-regained"), "network-regained is soft (won't burn circuit)")

print("=== playhead health ===")
expect(PlaybackResilience.playheadAdvanced(previous: 10, next: 10.4), "0.4s advance counts")
expect(!PlaybackResilience.playheadAdvanced(previous: 10, next: 10.1), "0.1s jitter ignored")

print("=== stuck thresholds (1s thrash prevention) ===")
expect(
    PlaybackResilience.stuckTickThreshold(bufferEmpty: false, waiting: false, playingFrozen: true) >= 10,
    "playing-frozen needs ≥5s before recover")
expect(
    PlaybackResilience.stuckTickThreshold(bufferEmpty: true, waiting: false, playingFrozen: false) == 6,
    "empty buffer recovers at ~3s")

print("=== corrupt cache loop ===")
expect(PlaybackResilience.shouldInvalidateCache(rebuildAttempt: 1), "1st rebuild nukes cache")
expect(PlaybackResilience.shouldInvalidateCache(rebuildAttempt: 2), "2nd rebuild still nukes cache")
expect(PlaybackResilience.maxRebuildsPerTrack == 3, "circuit breaker at 3")

print("=== soft seek policy ===")
expect(
    PlaybackResilience.canSoftSeek(softSeekCount: 0, rebuildCount: 0, reason: "waiting", hasCachedFile: false),
    "first wait can soft-seek")
expect(
    !PlaybackResilience.canSoftSeek(softSeekCount: 0, rebuildCount: 0, reason: "failedToEnd", hasCachedFile: false),
    "hard failure skips soft-seek")
expect(
    !PlaybackResilience.canSoftSeek(softSeekCount: 0, rebuildCount: 0, reason: "waiting", hasCachedFile: true),
    "cached file skips soft-seek → rebuild/cache path")

print("=== stub cache rejection ===")
expect(PlaybackResilience.minimumStreamCacheBytes(durationSeconds: nil) == 48_000, "default min 48KB")
expect(PlaybackResilience.minimumStreamCacheBytes(durationSeconds: 240) > 48_000, "long tracks need larger cache")
let stubSize = 20_000
expect(stubSize < PlaybackResilience.minimumStreamCacheBytes(durationSeconds: 180), "20KB stub rejected for 3min song")

// Simulate the old 1s thrash: keepUp flicker every 0.5s while playhead advances.
print("=== simulate old thrash vs new policy ===")
var ticks = 0
var playhead: TimeInterval = 0
var wouldRecover = false
for step in 0..<20 { // 10 seconds
    playhead += 0.5
    let keepUpFlicker = step % 2 == 0 // old bug used this
    let advanced = PlaybackResilience.playheadAdvanced(previous: playhead - 0.5, next: playhead)
    if !advanced && keepUpFlicker {
        ticks += 1
    } else if advanced {
        ticks = 0
    }
    if ticks >= 5 { wouldRecover = true }
}
expect(!wouldRecover, "advancing playhead never trips recovery despite keepUp flicker")

// Simulate true freeze: playhead stuck, buffer empty.
ticks = 0
wouldRecover = false
let frozen: TimeInterval = 42
var last = frozen
for _ in 0..<12 {
    let advanced = PlaybackResilience.playheadAdvanced(previous: last, next: frozen)
    let threshold = PlaybackResilience.stuckTickThreshold(
        bufferEmpty: true, waiting: false, playingFrozen: true)
    if !advanced {
        ticks += 1
        if ticks >= threshold { wouldRecover = true }
    }
}
expect(wouldRecover, "frozen playhead + empty buffer eventually recovers")

print("=== paused while wanting (live-report dead state) ===")
expect(
    PlaybackResilience.isPausedWhileWanting(wantsToPlay: true, isPaused: true, rate: 0),
    "want+paused+rate0 is dead state")
expect(
    !PlaybackResilience.isPausedWhileWanting(wantsToPlay: true, isPaused: false, rate: 1),
    "actually playing is not dead state")
expect(
    !PlaybackResilience.isPausedWhileWanting(wantsToPlay: false, isPaused: true, rate: 0),
    "user pause is not dead state")
expect(
    PlaybackResilience.stuckTickThreshold(
        bufferEmpty: false, waiting: false, playingFrozen: false, pausedWhileWanting: true) == 4,
    "paused-while-wanting recovers at ~2s")

// Simulate the live report: wantsToPlay, tcs=paused, full buffer, playhead stuck.
ticks = 0
wouldRecover = false
for _ in 0..<8 {
    let pausedWanting = PlaybackResilience.isPausedWhileWanting(
        wantsToPlay: true, isPaused: true, rate: 0)
    let threshold = PlaybackResilience.stuckTickThreshold(
        bufferEmpty: false, waiting: false, playingFrozen: false,
        pausedWhileWanting: pausedWanting)
    if pausedWanting {
        ticks += 1
        if ticks >= threshold { wouldRecover = true }
    }
}
expect(wouldRecover, "paused-while-wanting trips recovery within ~2s")

print("")
if failures == 0 {
    print("All playback resilience simulations passed.")
    exit(0)
} else {
    print("\(failures) simulation(s) failed.")
    exit(1)
}
