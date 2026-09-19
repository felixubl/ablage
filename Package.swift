// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Ablage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Ablage", path: "Sources/Ablage")
    ]
)
