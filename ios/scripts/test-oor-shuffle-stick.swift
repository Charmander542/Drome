#!/usr/bin/env swift
import Foundation

// Mirror of ShuffleEngine.sticksToOutOfRotationPool — keep in sync when changing policy.
// Run: swift ios/scripts/test-oor-shuffle-stick.swift

enum ShuffleEngine {
    static func sticksToOutOfRotationPool(
        allowsOutOfRotation: Bool,
        contextSongIDs: [String],
        excludedIDs: Set<String>
    ) -> Bool {
        if allowsOutOfRotation { return true }
        guard !contextSongIDs.isEmpty, !excludedIDs.isEmpty else { return false }
        return contextSongIDs.allSatisfy { excludedIDs.contains($0) }
    }
}

var failures = 0

func expect(_ name: String, _ got: Bool, equals expected: Bool) {
    if got != expected {
        fputs("FAIL \(name): got \(got), expected \(expected)\n", stderr)
        failures += 1
    } else {
        print("ok \(name)")
    }
}

expect(
    "system OOR context sticks",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: true,
        contextSongIDs: ["a", "b"],
        excludedIDs: ["a", "b"]),
    equals: true)

expect(
    "system OOR sticks even if exclusion set empty",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: true,
        contextSongIDs: ["a"],
        excludedIDs: []),
    equals: true)

expect(
    "all-OOR playlist sticks",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: false,
        contextSongIDs: ["a", "b", "c"],
        excludedIDs: ["a", "b", "c", "z"]),
    equals: true)

expect(
    "mixed playlist does not stick",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: false,
        contextSongIDs: ["a", "b", "in-rotation"],
        excludedIDs: ["a", "b"]),
    equals: false)

expect(
    "empty context does not stick",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: false,
        contextSongIDs: [],
        excludedIDs: ["a"]),
    equals: false)

expect(
    "empty exclusion does not stick without OOR context",
    ShuffleEngine.sticksToOutOfRotationPool(
        allowsOutOfRotation: false,
        contextSongIDs: ["a"],
        excludedIDs: []),
    equals: false)

if failures > 0 {
    fputs("\(failures) failure(s)\n", stderr)
    exit(1)
}
print("all passed")
