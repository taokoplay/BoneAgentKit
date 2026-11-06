// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ResourceReadingDemo",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "ResourceReadingDemo",
            dependencies: [.product(name: "BoneAgentKit", package: "BoneAgentKit")]
        )
    ]
)
