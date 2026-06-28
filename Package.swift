// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeSwapBar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeSwapBar",
            path: "Sources/ClaudeSwapBar"
        )
    ]
)
