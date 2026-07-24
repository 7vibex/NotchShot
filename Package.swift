// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchShot",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "NotchShot", targets: ["NotchShot"]),
        .executable(name: "notchshot-diagnostics", targets: ["NotchShotDiagnostics"]),
        .library(name: "NotchShotKit", targets: ["NotchShotKit"]),
    ],
    targets: [
        .executableTarget(
            name: "NotchShot",
            dependencies: ["NotchShotKit"],
            path: "Sources/NotchShot",
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
            path: "Sources/NotchShotKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "NotchShotKitTests",
            dependencies: ["NotchShotKit"],
            path: "Tests/NotchShotKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
