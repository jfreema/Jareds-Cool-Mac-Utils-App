// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "JaredsMacUtils",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "JaredsMacUtils", path: "Sources/JaredsMacUtils"),
        .testTarget(name: "JaredsMacUtilsTests", dependencies: ["JaredsMacUtils"], path: "Tests/JaredsMacUtilsTests"),
    ]
)
