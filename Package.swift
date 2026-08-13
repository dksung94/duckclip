// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DuckClip",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DuckClipCore", targets: ["DuckClipCore"]),
        .executable(name: "DuckClip", targets: ["DuckClipApp"]),
        .executable(name: "duckclip-hook", targets: ["DuckClipHook"]),
        .executable(name: "duckclipctl", targets: ["DuckClipCtl"])
    ],
    dependencies: [
        // Command Line Tools installations can omit bundled test modules. Pin
        // the matching Swift Testing release so the test suite stays portable.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "cd448bbe5cc989d8693ca75e9b08593eb143dea1"
        )
    ],
    targets: [
        .systemLibrary(
            name: "CSQLite",
            pkgConfig: "sqlite3",
            providers: [.brew(["sqlite3"])]
        ),
        .target(
            name: "DuckClipCore",
            dependencies: ["CSQLite"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "DuckClipApp",
            dependencies: ["DuckClipCore"]
        ),
        .executableTarget(
            name: "DuckClipHook"
        ),
        .executableTarget(
            name: "DuckClipCtl",
            dependencies: ["DuckClipCore"]
        ),
        .executableTarget(
            name: "DuckClipChecks",
            dependencies: ["DuckClipCore"],
            path: "Checks"
        ),
        .testTarget(
            name: "DuckClipCoreTests",
            dependencies: [
                "DuckClipCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
