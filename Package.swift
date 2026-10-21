// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Copipe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Copipe", path: "Sources/Copipe")
    ]
)
