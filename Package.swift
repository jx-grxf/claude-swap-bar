// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwapBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .executableTarget(
            name: "ClaudeSwapBar",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/ClaudeSwapBar",
            resources: [
                .copy("Resources/AppLogo.png"),
                .copy("Resources/StatusIcon.svg"),
            ]
        )
    ]
)
