// swift-tools-version: 5.9
import PackageDescription

/// Headless tests for CarPlay list policy (no CarPlay / Xcode required).
/// Source is synced from `Drome/CarPlay/CarPlayListPolicy.swift` by
/// `scripts/test-carplay-policy.sh` (same pattern as PodcastKit).
let package = Package(
    name: "CarPlayPolicy",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CarPlayListPolicy", targets: ["CarPlayListPolicy"])
    ],
    targets: [
        .target(
            name: "CarPlayListPolicy",
            path: "Sources/CarPlayListPolicy"
        ),
        .testTarget(
            name: "CarPlayListPolicyTests",
            dependencies: ["CarPlayListPolicy"],
            path: "Tests"
        )
    ]
)
