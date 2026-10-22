// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClaudeMenu",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ClaudeMenu", path: "Sources/ClaudeMenu")
    ]
)
