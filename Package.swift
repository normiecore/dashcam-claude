// swift-tools-version: 5.9
import PackageDescription

// Portable storage-policy gate. The actual camera and AVAssetWriter targets require iOS.
let package = Package(
    name: "DashcamCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "DashcamCore", targets: ["DashcamCore"])],
    targets: [
        .target(name: "CRetentionPolicy", path: "Core", sources: ["RetentionPolicy.c"], publicHeadersPath: "."),
        .target(name: "DashcamCore", dependencies: ["CRetentionPolicy"], path: "Core", sources: ["RecordingStore.swift"]),
        .testTarget(name: "DashcamCoreTests", dependencies: ["DashcamCore"], path: "Tests", sources: ["RecordingStoreTests.swift"]),
    ]
)
