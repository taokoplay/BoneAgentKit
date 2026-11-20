// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WorkflowRunnerDemo",
    platforms: [.macOS(.v13)],
    dependencies: [.package(path: "../..")],
    targets: [
        .executableTarget(
            name: "WorkflowRunnerDemo",
            dependencies: [
                .product(name: "BoneAgentKit", package: "BoneAgentKit"),
                .product(name: "BoneAgentTools", package: "BoneAgentKit"),
                .product(name: "BoneAgentTesting", package: "BoneAgentKit"),
                .product(name: "BoneAgentLocalModels", package: "BoneAgentKit")
            ]
        ),
        .testTarget(name: "WorkflowRunnerDemoTests", dependencies: ["WorkflowRunnerDemo"])
    ]
)
