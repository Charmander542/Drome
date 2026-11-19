#!/usr/bin/env swift
import Foundation

// Mirror of ServerURLNormalization — keep in sync when changing policy.
// Run: swift ios/scripts/test-url-normalization.swift

enum ServerURLNormalization {
    static func normalize(_ raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if !trimmed.contains("://") {
            trimmed = "https://" + trimmed
        }
        guard var components = URLComponents(string: trimmed),
              let host = components.host, !host.isEmpty else { return nil }
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.url
    }
}

var failures = 0

func expect(_ name: String, _ raw: String, equals expected: String?) {
    let got = ServerURLNormalization.normalize(raw)?.absoluteString
    if got != expected {
        fputs("FAIL \(name): got \(got ?? "nil"), expected \(expected ?? "nil")\n", stderr)
        failures += 1
    } else {
        print("ok \(name)")
    }
}

expect("empty", "", equals: nil)
expect("whitespace", "   ", equals: nil)
expect("bare host defaults https", "wishlist.charlesvanhook.com",
       equals: "https://wishlist.charlesvanhook.com")
expect("bare host with port", "192.168.8.193:4534",
       equals: "https://192.168.8.193:4534")
expect("explicit http preserved", "http://192.168.8.193:4534",
       equals: "http://192.168.8.193:4534")
expect("explicit https preserved", "https://wishlist.charlesvanhook.com",
       equals: "https://wishlist.charlesvanhook.com")
expect("strip trailing slash", "https://wishlist.charlesvanhook.com/",
       equals: "https://wishlist.charlesvanhook.com")
expect("strip path slash", "https://music.example.com/navidrome/",
       equals: "https://music.example.com/navidrome")
expect("trim whitespace", "  wishlist.example.com  ",
       equals: "https://wishlist.example.com")
expect("invalid", "://", equals: nil)

if failures > 0 {
    fputs("\(failures) failure(s)\n", stderr)
    exit(1)
}
print("all passed")
