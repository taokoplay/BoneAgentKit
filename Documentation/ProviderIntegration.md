# 扩展 BoneAgentKit

## 接入新的文本 Provider

Provider 扩展直接实现 `BoneInferenceEngine`，并复用统一的配置、请求构造、Transport 和响应验证边界；不要为单个供应商建立平行 DTO、HTTP Client 或错误体系。

```swift
import BoneAgentKit
import Foundation

struct ExampleTextInferenceEngine: BoneInferenceEngine {
    let configuration: BoneInferenceProviderConfiguration
    let transport: any BoneInferenceHTTPTransport

    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        var urlRequest = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: configuration,
            operation: "chat",
            defaultPath: "/v1/messages",
            method: "POST"
        )
        let messages: [[String: String]] = request.messages.compactMap { message in
            guard let content = message.content else { return nil }
            return ["role": message.role.rawValue, "content": content]
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": request.modelID,
            "messages": messages,
        ])
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        guard let text = json["text"] as? String, !text.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return BoneInferenceResponse(text: text)
    }
}
```

这是结构示例，不代表某个真实 Provider 协议。正式实现必须依据供应商官方公开 API：

- 通过 `BoneInferenceProviderConfiguration` 注入凭据、Base URL、协议和端点；
- 通过 `BoneInferenceProviderRequestBuilder` 执行最终 URL 与 Header 门禁；
- POST 不自动重试，模型发现 GET 只能使用有限重试入口；
- 通过 `BoneInferenceProviderResponseValidator` 映射稳定状态与结构化 safety；
- 不把 Prompt、响应正文、凭据、完整 URL、Cookie 或 Authorization 写入错误、日志、事件和 Harness 报告；
- Streaming 必须在协议完整终态后返回统一 Response，不发布半截 token。

如果新 Provider 需要图片能力，实现独立 `BoneInferenceImageGenerating`，并让 Engine 的 `imageGenerator` 非空；不要把 `.imageGeneration` 直接放入 `nonImageCapabilities`。图片 URL/Base64/Data 仍由 App Host 物化，Kit 不负责数据库、缓存或 UI。

## 创建第一个 Tool

从 `Templates/MinimalTool.swift.txt` 复制。必须修改稳定 `id`、元数据、Input/Output 与执行逻辑；保留 Swift 6 的 `Codable & Sendable` 和强类型边界。`BoneAnyAgentTool` 只应在 Registry 组装点出现。

## 注入项目 Service

从 `Templates/ProjectTool.swift.txt` 复制。项目 Service 通过实现 `BoneAgentToolContext` 的 Context 注入，Tool 调用 `context.service`；不得让通用 Kit 直接 import App 数据库、模型或 UI。

```text
UI ───────────────→ ProjectService
Agent Tool Adapter → ProjectService
Harness ──────────→ ProjectService
```

项目接入使用**协议组合**而非 `BaseAgent`。删除 Tool/Provider 实现后，ProjectService 仍应能被 UI 与测试调用。

## 版权、来源与图片权利门禁

- 每个迁移或 Provider 文件都做**逐文件 provenance**：原路径/官方规范、原提交（如适用）、迁移方式、回归证据和审查人。
- 引入任何第三方实质代码必须**事前审批**；审批前不得复制代码、注释、文档、Fixture、错误映射或 SSE 实现。
- 只有真实纳入材料时，才按许可证条件保留版权声明并增加对应 `LICENSE` / `NOTICE`；不能凭空添加，也不能遗漏必要条件。
- AgentRunKit、SwiftHarnessAgent、SwiftLangChain 等**参考框架只学思想不复制**，包括独特 API 组合和命名。
- 供应商官方 API 行为可作为独立实现依据；非官方 SDK 不自动成为可复制来源。

图片生成的内容权利不由 Kit 保证。项目必须按供应商条款治理用户输入、参考图来源与允许用途，记录必要的来源/用途，并处理版权、商标、肖像和内容政策；外部发布前按项目风险进行用户确认或法律审查。

详见 `LicensingAndProvenance.md` 与 `ThirdPartySources.md`。
