// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TokenBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TokenBar", targets: ["TokenBar"]),
        .executable(name: "tokenbar-cli", targets: ["tokenbar-cli"]),
    ],
    targets: [
        .target(
            name: "LocalCore",
            path: "Sources/LocalCore",
            // Resources/prices-snapshot.json is the readable copy of PriceSnapshotData.swift (same text, written by
            // scripts/update-prices.py); a Swift string compiles in seconds where a byte array takes 40.
            exclude: ["Resources"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TokenBarUI",
            dependencies: ["LocalCore"],
            path: "Sources/TokenBarUI"
        ),
        .executableTarget(
            name: "TokenBar",
            dependencies: ["TokenBarUI"],
            path: "Sources/TokenBar"
        ),
        .executableTarget(
            name: "tokenbar-cli",
            dependencies: ["LocalCore"],
            path: "Sources/tokenbar-cli"
        ),
        // Swift Testing is not usable with Command Line Tools only, so the suite
        // is a plain executable: `swift run TokenChecks`.
        .executableTarget(
            name: "TokenChecks",
            dependencies: ["LocalCore"],
            path: "Sources/TokenChecks"
        ),
        // Dev-only: renders the panel and the dashboard to images and checks the UI invariants.
        .executableTarget(
            name: "UISnapshot",
            dependencies: ["TokenBarUI", "LocalCore"],
            path: "Sources/UISnapshot"
        ),
    ],
    swiftLanguageModes: [.v5]
)
