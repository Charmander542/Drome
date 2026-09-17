#!/usr/bin/env swift
import Foundation

/// Mirrors `MiniPlayerKind.resolve` — keep in sync with MainTabView.swift.
enum MiniPlayerKind: Equatable {
    case none, music, podcast

    static func resolve(hasMusicCurrent: Bool, hasPodcastEpisode: Bool) -> MiniPlayerKind {
        if hasPodcastEpisode { return .podcast }
        if hasMusicCurrent { return .music }
        return .none
    }
}

var failures = 0
func expect(_ name: String, _ got: MiniPlayerKind, _ want: MiniPlayerKind) {
    if got != want {
        fputs("FAIL \(name): got \(got) want \(want)\n", stderr)
        failures += 1
    } else {
        print("OK   \(name)")
    }
}

expect("idle", MiniPlayerKind.resolve(hasMusicCurrent: false, hasPodcastEpisode: false), .none)
expect("music only", MiniPlayerKind.resolve(hasMusicCurrent: true, hasPodcastEpisode: false), .music)
expect("podcast only", MiniPlayerKind.resolve(hasMusicCurrent: false, hasPodcastEpisode: true), .podcast)
expect("podcast replaces music", MiniPlayerKind.resolve(hasMusicCurrent: true, hasPodcastEpisode: true), .podcast)

if failures > 0 {
    fputs("\(failures) failure(s)\n", stderr)
    exit(1)
}
print("All MiniPlayerKind cases passed.")
