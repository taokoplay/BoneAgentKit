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
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: capabilities,
            invocation: .nonStreaming
        )
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

- 在构造 URLRequest 和调用 Transport 前使用 `BoneInferenceCapabilityValidator`，确保请求所需 Text、Tool Calling、Structured Output 或 Streaming 能力已满足；
- 结构化输出 fallback 必须由 `BoneInferenceResponseFormat` 显式允许，不能由 Provider 静默降级；
- Model 级能力无法核验时保持 unknown，不按模型名或兼容协议名称猜测；
- 通过 `BoneInferenceProviderConfiguration` 注入凭据、Base URL、协议和端点；
- 通过 `BoneInferenceProviderRequestBuilder` 执行最终 URL 与 Header 门禁；
- POST 不自动重试，模型发现 GET 只能使用有限重试入口；
- 通过 `BoneInferenceProviderResponseValidator` 映射稳定状态与结构化 safety；
- 不把 Prompt、响应正文、凭据、完整 URL、Cookie 或 Authorization 写入错误、日志、事件和 Harness 报告；
- Streaming 必须在协议完整终态后返回统一 Response，不发布半截 token。

## 可读推理披露

`BoneInferenceRequest.reasoningDisclosure` 默认为 `.hidden`。业务只有通过
`BoneInferenceDetailedResultProviding` 或 `BoneInferenceDetailedStreaming` 才能取得内存中的
`BoneInferenceDetailedResult.reasoning`：

- `.hidden` 不交付任何可读推理；
- `.summary` 只交付 Provider 明确标记的摘要；
- `.providerReadable` 可交付已核验字段中的可读 thinking/reasoning 原文，只有摘要时允许降级为摘要。

推理文本不得进入 `BoneInferenceAssistantTurn`、Tool 参数、普通 Codable 检查点或 SDK 日志。
`signature`、`thoughtSignature`、`redacted_thinking`、encrypted/opaque continuation 永不作为推理文本披露；
它们如为续传必需，只能留在有界的 `BoneInferenceProviderContinuation`。可选推理超过 256 KiB 时丢弃推理，
不得破坏已经验证的正式响应。当前详细 Streaming 仍在完整终态后一次性交付；真正逐事件
`AsyncThrowingStream` 属于第二阶段 API。

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
