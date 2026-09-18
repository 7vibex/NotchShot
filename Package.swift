// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchShot",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotchShot", targets: ["NotchShot"]),
        .executable(name: "NotchShotOSDRecovery", targets: ["NotchShotOSDRecovery"]),
        .executable(name: "NotchShotAdapterRunner", targets: ["NotchShotAdapterRunner"]),
        .executable(name: "NotchShotAIReporter", targets: ["NotchShotAIReporter"]),
        .executable(name: "notchshot-diagnostics", targets: ["NotchShotDiagnostics"]),
        .executable(name: "notchshot-cli", targets: ["NotchShotCLI"]),
        .library(name: "NotchShotKit", targets: ["NotchShotKit"]),
    ],
    dependencies: [
        // Pinned exactly, because the updater is a privileged install path and a
        // signed release must be reproducible. That makes the pin a standing
        // obligation: 2.9.5 and 2.9.6 each carried symlink and privilege
        // fixes that a stale `exact:` would have silently skipped.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.6"),
    ],
    targets: [
        .executableTarget(
            name: "NotchShot",
            dependencies: ["NotchShotKit"],
            path: "Sources/NotchShot",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // A tiny lease watchdog. If the main process crashes while it has
        // paused OSDUIHelper, stdin closes and this process immediately resumes
        // the validated Apple helper.
        .executableTarget(
            name: "NotchShotOSDRecovery",
            path: "Sources/NotchShotOSDRecovery",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Establishes a dedicated process group before executing the optional
        // user-approved media adapter, allowing bounded descendant cleanup.
        .executableTarget(
            name: "NotchShotAdapterRunner",
            path: "Sources/NotchShotAdapterRunner",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Receives explicit lifecycle events from Claude, Codex, and Cursor
        // hooks and writes a small local status record for the island.
        .executableTarget(
            name: "NotchShotAIReporter",
            dependencies: ["NotchShotAIReporterSupport"],
            path: "Sources/NotchShotAIReporter",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // `notchshot-cli activity …`: publishes bounded Live Activities to the
        // app over its owner-only local socket. Shares the wire format with the
        // app through NotchShotAIReporterSupport, never AppKit.
        .executableTarget(
            name: "NotchShotCLI",
            dependencies: ["NotchShotAIReporterSupport"],
            path: "Sources/NotchShotCLI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NotchShotAIReporterSupport",
            path: "Sources/NotchShotAIReporterSupport",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Headless smoke test for the capture pipeline: tells you whether a
        // failed capture is a code problem or a permission problem.
        .executableTarget(
            name: "NotchShotDiagnostics",
            dependencies: ["NotchShotKit"],
            path: "Sources/NotchShotDiagnostics",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "NotchShotKit",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "NotchShotAIReporterSupport",
            ],
            path: "Sources/NotchShotKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Performance benchmarks for the latency-sensitive paths. Not part of
        // any shipped product — `Scripts/build_app.sh` builds products by name,
        // so this never reaches the bundle. Run with:
        //   swift run -c release NotchShotBench
        .executableTarget(
            name: "NotchShotBench",
            dependencies: ["NotchShotKit", "NotchShotAIReporterSupport"],
            path: "Sources/NotchShotBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NotchShotKitTests",
            dependencies: ["NotchShotKit", "NotchShotAIReporterSupport"],
            path: "Tests/NotchShotKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
