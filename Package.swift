// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Hauntty",
    platforms: [.macOS(.v26)],
    targets: [
        // Built by scripts/build-ghosttykit.sh from the pinned submodule.
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/GhosttyKit.xcframework"
        ),
        // tmux control mode and the tab model. No AppKit or GhosttyKit, so the
        // tests can run without the app.
        .target(
            name: "HaunttyCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Hauntty",
            dependencies: ["GhosttyKit", "HaunttyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedLibrary("c++"),
            ]
        ),
        .testTarget(
            name: "HaunttyCoreTests",
            dependencies: ["HaunttyCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
