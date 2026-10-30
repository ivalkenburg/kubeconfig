// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KubeConfig",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KubeConfigCore", targets: ["KubeConfigCore"]),
        .executable(name: "KubeConfig", targets: ["KubeConfig"])
    ],
    dependencies: [.package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")],
    targets: [
        .target(name: "KubeConfigCore", dependencies: ["Yams"]),
        .executableTarget(name: "KubeConfig", dependencies: ["KubeConfigCore"]),
        .testTarget(name: "KubeConfigCoreTests", dependencies: ["KubeConfigCore", "Yams"]),
        .testTarget(name: "KubeConfigAppTests", dependencies: ["KubeConfig", "KubeConfigCore"])
    ],
    swiftLanguageModes: [.v5]
)
