// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Limits",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Limits", path: "Sources/Limits")
    ]
)
