// swift-tools-version: 5.9
import PackageDescription

// Standalone test harness for the pure playback-queue logic. This does NOT affect
// the Xcode app build (Xcode ignores this manifest). Run with:  swift test
let package = Package(
    name: "PlaybackCore",
    targets: [
        .target(
            name: "PlaybackCore",
            path: "Shared",
            sources: ["PlaybackQueue.swift"]
        ),
        .testTarget(
            name: "PlaybackCoreTests",
            dependencies: ["PlaybackCore"],
            path: "Tests/PlaybackCoreTests"
        ),
    ]
)
