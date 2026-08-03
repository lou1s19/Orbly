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
        // Prüft die Logik, die man nicht durch Anklicken verifizieren kann:
        // Segment-Zusammenbau von whisper, Statistik-Rechnung und Verdichtung,
        // Gleichstand der 5 Sprachtabellen.
        .testTarget(
            name: "OrblyTests",
            dependencies: ["Orbly"],
            path: "Tests/OrblyTests"
        )
    ]
)
