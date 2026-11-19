// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LyricsSearchKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "LyricsSearchKit", targets: ["LyricsSearchKit"]),
    ],
    targets: [
        .target(name: "LyricsSearchKit"),
        .testTarget(
            name: "LyricsSearchKitTests",
            dependencies: ["LyricsSearchKit"]
        ),
    ]
)
