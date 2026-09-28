// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Spotcat",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Spotcat", path: "Sources/Spotcat")
    ]
)
