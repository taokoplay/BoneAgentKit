# 5 分钟快速开始

本页只介绍 **Model / Inference、Tool、Agent** 三件事。示例使用当前 `maximumSteps` 和 `BoneAgentKit` Facade API；把 `ExistingModelAdapter` 换成项目已有模型 SDK 的适配器即可。

## Model

Model 通过 `BoneInferenceEngine` 接入。已有 SDK 只需包装为这个协议，不要把 SDK 源码复制进 Kit。

```swift
import Foundation

struct ExistingModelAdapter: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        // 用项目已有 SDK 发送 request.modelID 与 request.messages。
        // 此处仅以可运行占位结果展示协议形状。
        return BoneInferenceResponse(text: "Hello from the model")
    }
}
```

## Tool

第一个 Tool 使用 `BoneAgentEmptyContext`，输入输出保持 `Codable & Sendable`，不使用 `[String: Any]`。

```swift
struct EchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let text: String }
    struct Output: Codable, Sendable { let text: String }
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "example.echo", version: "1", title: "Echo", summary: "返回输入文本"
    )

    func execute(input: Input, context: Context) async throws -> Output {
        Output(text: input.text)
    }
}
```

## Agent

```swift
@main
struct QuickStartExample {
    static func main() async throws {
        let registry = try BoneAgentToolRegistry(
            tools: [BoneAnyAgentTool(EchoTool())]
        )
        let kit = BoneAgentKit(
            inferenceEngine: ExistingModelAdapter(),
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 4)
        )

        let result = try await kit.run(
            modelID: "project-model-id",
            messages: [BoneInferenceMessage(role: .user, content: "Say hello")]
        )
        guard result.steps == 1 else { throw QuickStartError.unexpectedSteps }
    }
}

enum QuickStartError: Error {
    case unexpectedSteps
}
```

最短路径完成。下一步按顺序阅读：

1. **5 分钟快速开始**（本页）
2. **接入已有模型 SDK**：见 [Provider 接入与扩展](ProviderIntegration.md#接入已有模型-sdk)
3. **创建第一个 Tool**：复制 [MinimalTool 模板](Templates/MinimalTool.swift.txt)
4. **注入项目 Service**：复制 [ProjectTool 模板](Templates/ProjectTool.swift.txt)
5. **测试 Tool 与 Agent**：见 [TestingAndHarness](Testing.md)
6. **观察运行事件**：见 [TestingAndHarness](Testing.md#观察运行事件)
7. **排查失败**：见 [TestingAndHarness](Testing.md#排查失败)
8. **迁移 Package**：见 [MigrationToSwiftPackage](PackageIntegration.md)
