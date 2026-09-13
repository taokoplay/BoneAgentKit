# 5 分钟快速开始

> **目标：** 定义一个 Inference Engine、一个强类型 Tool，并完成一次 Agent Run。

本页只介绍 **Model / Inference、Tool、Agent** 三件事。把 `ExistingModelAdapter` 换成已有模型 SDK 的适配器即可。BoneAgentKit 采用 Agent Harness 架构，生产 API 按 `Agent + Inference + Workflow` 领域组织。

[返回文档地图](INDEX.md) · [查看架构说明](Architecture.md#agent-harness-架构定位)

## 日志与 Debug 模式

`BoneAgentConfiguration` 支持注入日志记录器，并控制 Debug 日志。默认关闭 Debug 日志。

开启 Debug 元数据日志（默认不记录完整请求正文）：

```swift
let configuration = try BoneAgentConfiguration(
    maximumSteps: 10,
    logging: .init(isDebugEnabled: true, minimumLevel: .debug)
)
```

关闭 Debug 日志（默认配置）：

```swift
let configuration = try BoneAgentConfiguration(
    maximumSteps: 10,
    logging: .init(isDebugEnabled: false)
)
```

设置最低日志级别，例如仅输出警告和错误：

```swift
let configuration = try BoneAgentConfiguration(
    maximumSteps: 10,
    logging: .init(minimumLevel: .warning)
)
```

Debug 模式默认不记录完整请求正文。若确需受控调试，可显式设置
`logging: .init(isDebugEnabled: true, minimumLevel: .debug, includesSensitivePayloads: true)`。
该选项可能记录用户消息与 Tool 参数，不应在生产环境常开。
响应成功日志名称为 `inference.result.validated`，表示 Engine 返回有效结果，不能作为收到 HTTP 响应的证据。
解析前的安全响应诊断见 [Provider 接入](ProviderIntegration.md#非流式安全响应诊断)。

## Model

Model 通过 `BoneInferenceEngine` 接入。已有 SDK 只需包装为这个协议，不要把 SDK 源码复制进 Kit。

```swift
import Foundation
import BoneAgentKit

struct ExistingModelAdapter: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
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
        let agent = BoneAgent(
            inferenceEngine: ExistingModelAdapter(),
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 4)
        )

        let result = try await agent.run(
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

此示例注册了 Echo Tool，但占位 Engine 直接返回文本，因此不会实际调用 Tool；验证 Tool 路径需让 Engine 返回相应 Tool Call，或使用测试 Product 的 Scripted Engine。将本页三个 Swift 代码块合并为可执行目标源码即可编译。

该最短路径只完成进程内的一次 Agent Run，不会自动创建 Workflow、保存检查点或在重启后续跑。需要跨重启任务恢复时，另行接入 [Host Persistence Adapter](CharacterHostIntegration.md#persistence-adapter)；短期只读助手不必为此保存对话。

最短路径完成。下一步按顺序阅读：

1. **5 分钟快速开始**（本页）
2. **接入已有模型 SDK**：见 [Provider 接入与扩展](ProviderIntegration.md#接入已有模型-sdk)
3. **创建第一个 Tool**：复制 [MinimalTool 模板](Templates/MinimalTool.swift.txt)
4. **注入项目 Service**：复制 [ProjectTool 模板](Templates/ProjectTool.swift.txt)
5. **测试 Tool 与 Agent**：见 [Testing](Testing.md)
6. **观察运行事件**：见 [Testing](Testing.md#观察运行事件)
7. **排查失败**：见 [Testing](Testing.md#排查失败)
8. **接入 Package**：见 [Package 接入](PackageIntegration.md)

---

[返回文档地图](INDEX.md) · [下一篇：Provider 与 Tool 扩展](ProviderIntegration.md)
