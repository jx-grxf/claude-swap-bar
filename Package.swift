// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CSwapBar",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.2"),
    ],
    targets: [
        .target(
            name: "CSwapKit",
            path: "Sources/CSwapKit"
        ),
        .executableTarget(
            name: "cswap",
            dependencies: ["CSwapKit"],
            path: "Sources/cswap"
        ),
        .executableTarget(
            name: "CSwapBar",
            dependencies: [
                "CSwapKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/CSwapBar",
            resources: [
                .copy("Resources/AppLogo.png"),
                .copy("Resources/StatusIcon.svg"),
            ]
        ),
    ]
)
