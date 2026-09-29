// swift-tools-version: 6.0
// DashcamCore: platform-independent recording, retention and incident logic.
// This package intentionally has no AVFoundation/UIKit dependency so it builds and tests on Linux
// (swift build / swift test) as well as inside the iOS app. The AVFoundation capture layer lives in App/.
import PackageDescription

let package = Package(
    name: "DashcamCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "DashcamCore", targets: ["DashcamCore"]),
    ],
    targets: [
        .target(
            name: "DashcamCore",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "DashcamCoreTests",
            dependencies: ["DashcamCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
