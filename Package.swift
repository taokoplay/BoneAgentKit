// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoneAgentKit",
    platforms: [
        .iOS(.v13),
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "BoneAgentKit",
            targets: ["BoneAgentKit"]
        ),
        .library(
            name: "BoneAgentTesting",
            targets: ["BoneAgentTesting"]
        ),
        .library(
            name: "BoneAgentProviderAssets",
            targets: ["BoneAgentProviderAssets"]
        ),
        .executable(
            name: "BoneAgentLiveProviderSmoke",
            targets: ["BoneAgentLiveProviderSmoke"]
        ),
    ],
    targets: [
        .target(
            name: "BoneAgentKit",
            resources: [.process("Resources")]
        ),
        .target(
            name: "BoneAgentTesting",
            dependencies: ["BoneAgentKit"]
        ),
        .target(
            name: "BoneAgentProviderAssets",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "BoneAgentLiveProviderSmoke",
            dependencies: ["BoneAgentKit"]
        ),
        .testTarget(
            name: "BoneAgentKitTests",
            dependencies: ["BoneAgentKit", "BoneAgentTesting"]
        ),
        .testTarget(
            name: "BoneAgentTestingTests",
            dependencies: ["BoneAgentTesting", "BoneAgentKit"]
        ),
        .testTarget(
            name: "BoneAgentProviderAssetsTests",
            dependencies: ["BoneAgentProviderAssets"]
        ),
    ]
)
