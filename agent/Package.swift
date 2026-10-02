// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "wallpad",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(name: "wallpad", path: "Sources/wallpad", exclude: ["remote.html"]),
    ]
)
