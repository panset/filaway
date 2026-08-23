// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Filaway",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FilawayCore", targets: ["FilawayCore"]),
        .executable(name: "FilawayApp", targets: ["FilawayApp"]),
        .executable(name: "filaway-bench", targets: ["FilawayBench"]),
    ],
    dependencies: [
        // Upper bound: GRDB 7.9.0+ declares swift-tools-version 6.1, which the
        // Command Line Tools 6.0.3 toolchain on this machine cannot read.
        // Raise it once Xcode / a 6.1 toolchain is installed (plan §8).
        .package(url: "https://github.com/groue/GRDB.swift", "7.0.0" ..< "7.9.0"),
        .package(url: "https://github.com/swiftlang/swift-markdown", from: "0.8.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.0"),
    ],
    targets: [
        // All logic lives here. Never imports AppKit or SwiftUI (see CLAUDE.md).
        .target(
            name: "FilawayCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            // Versioned prompt text (M2-01/M2-06/M3-05), loaded through
            // `PromptLibrary`. SwiftPM resources must live inside the target
            // directory, so these sit here rather than in a top-level
            // `Prompts/` folder as plan §2.7 sketched — see docs/decisions.md.
            // `Resources/Models` carries the bundled Core ML embedder (M3-01):
            // the 63.5 MB fp16 bge-small `.mlpackage`, its descriptor JSON and
            // the WordPiece vocabulary. `.copy` keeps the `.mlpackage`
            // directory intact — `MLModel.compileModel(at:)` needs it verbatim
            // — and `EmbedderFactory` resolves it through `Bundle.module`.
            resources: [.copy("AI/Prompts"), .copy("Resources/Models")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Thin SwiftUI/AppKit shell. Swift 5 mode for AppKit interop, with
        // complete strict-concurrency checking surfaced as warnings.
        .executableTarget(
            name: "FilawayApp",
            dependencies: ["FilawayCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .executableTarget(
            name: "FilawayBench",
            dependencies: [
                "FilawayCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FilawayCoreTests",
            dependencies: ["FilawayCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
