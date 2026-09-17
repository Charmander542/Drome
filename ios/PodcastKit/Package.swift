// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PodcastKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "PodcastKit", targets: ["PodcastKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "PodcastKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "PodcastKitTests",
            dependencies: ["PodcastKit"],
            resources: [
                .copy("Fixtures"),
            ]
        ),
    ]
)
