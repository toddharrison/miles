// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Miles",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "MilesCore", targets: ["MilesCore"]),
        .library(name: "MilesAI", targets: ["MilesAI"]),
        .executable(name: "miles-cli", targets: ["miles-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
    ],
    targets: [
        // Logic. Must not import SwiftUI or AppKit (enforced by a test).
        .target(name: "MilesCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        // AI providers behind a protocol; on-device only.
        .target(name: "MilesAI", dependencies: ["MilesCore"]),
        .executableTarget(name: "miles-cli", dependencies: ["MilesCore", "MilesAI"]),
        .testTarget(name: "MilesCoreTests", dependencies: ["MilesCore", "MilesAI"]),
        .testTarget(name: "MilesAITests", dependencies: ["MilesAI", "MilesCore"]),
    ]
)
