// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Orbly",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Orbly",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Orbly"
        ),
        // Covers the logic that cannot be verified by clicking around:
        // assembling whisper segments, the statistics maths and compaction,
        // and parity of the 5 language tables.
        .testTarget(
            name: "OrblyTests",
            dependencies: ["Orbly"],
            path: "Tests/OrblyTests"
        )
    ]
)
