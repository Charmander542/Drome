// swift-tools-version: 5.9
import PackageDescription

/// Headless tests for LRC timing / active-line selection (no Xcode UI required).
/// Source is synced from `Drome/Core/Services/LRCParser.swift` by
/// `scripts/test-lyrics-timing.sh` (same pattern as CarPlayPolicy).
let package = Package(
    name: "LyricsTiming",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "LRCParser", targets: ["LRCParser"])
    ],
    targets: [
        .target(
            name: "LRCParser",
            path: "Sources/LRCParser"
        ),
        .testTarget(
            name: "LRCParserTests",
            dependencies: ["LRCParser"],
            path: "Tests"
        )
    ]
)
