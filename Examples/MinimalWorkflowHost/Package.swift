// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimalWorkflowHost",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "MinimalWorkflowHost",
            dependencies: [
                .product(name: "BoneAgentKit", package: "BoneAgentKit"),
                .product(name: "BoneAgentTesting", package: "BoneAgentKit"),
            ]
        ),
    ]
)
