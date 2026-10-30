// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Visualiser",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "Visualiser", path: "Sources")]
)
