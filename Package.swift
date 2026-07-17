// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwapBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeSwapBar",
            path: "Sources/ClaudeSwapBar",
            resources: [.copy("Resources/AppLogo.png")]
        )
    ]
)
