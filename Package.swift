// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ScreenBuffer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "ScreenBuffer",
            path: "Sources/ScreenBuffer"
        )
    ]
)
