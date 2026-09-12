// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Wave",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "wave", targets: ["WaveApp"]),
        .executable(name: "wave-spike", targets: ["WaveSpike"]),
        .library(name: "WaveCore", targets: ["WaveCore"]),
    ],
    targets: [
        // Real-time-safe primitives implemented in C11 (<stdatomic.h>).
        // Kept in C so the lock-free parameter cells are guaranteed wait-free and
        // free of any Swift runtime traffic (ARC, exclusivity checks) on the
        // audio render thread.
        .target(
            name: "WaveRTSupport",
            publicHeadersPath: "include"
        ),

        // Platform-independent domain logic. Deliberately free of Core Audio,
        // AppKit and SwiftUI so that it is exhaustively unit-testable.
        .target(
            name: "WaveCore",
            dependencies: ["WaveRTSupport"]
        ),

        // Core Audio HAL layer: discovery, taps, aggregate devices, render loop.
        .target(
            name: "WaveAudio",
            dependencies: ["WaveCore", "WaveRTSupport"]
        ),

        // SwiftUI menu-bar front end.
        .executableTarget(
            name: "WaveApp",
            dependencies: ["WaveCore", "WaveAudio"]
        ),

        // Headless spike / diagnostic CLI that exercises the full audio chain.
        .executableTarget(
            name: "WaveSpike",
            dependencies: ["WaveCore", "WaveAudio"]
        ),

        .testTarget(
            name: "WaveCoreTests",
            dependencies: ["WaveCore"]
        ),
    ]
)
