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
            name: "BoneAgentLocalModels",
            targets: ["BoneAgentLocalModels"]
        ),
        .library(
            name: "BoneAgentLlama",
            targets: ["BoneAgentLlama"]
        ),
        .executable(
            name: "BoneAgentLiveProviderSmoke",
            targets: ["BoneAgentLiveProviderSmoke"]
        ),
    ],
    targets: [
        .target(
            name: "BoneAgentKit",
            dependencies: ["BoneAgentProviderAssets"],
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
        .target(
            name: "BoneAgentLocalModels",
            dependencies: ["BoneAgentKit"]
        ),
        .target(
            name: "BoneAgentLlama",
            dependencies: ["BoneAgentKit", "BoneAgentLocalModels"]
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
        .testTarget(
            name: "BoneAgentLocalModelsTests",
            dependencies: ["BoneAgentLocalModels", "BoneAgentKit"]
        ),
        .testTarget(
            name: "BoneAgentLlamaTests",
            dependencies: ["BoneAgentLlama", "BoneAgentLocalModels", "BoneAgentKit"]
        ),
    ]
)
