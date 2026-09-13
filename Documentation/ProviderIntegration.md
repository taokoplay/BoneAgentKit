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
- Model 级能力无法核验时保持 unknown，不按模型名或兼容协议名称猜测；请求级 `.constrainedOutput` 还必须匹配 `.providerSmoke` 的 `BoneProviderCapabilityVerificationIdentity`，仅有官方文档证据不能授权；
- 通过 `BoneInferenceProviderConfiguration` 注入凭据、Base URL、协议和端点；
- 通过 `BoneInferenceProviderRequestBuilder` 执行最终 URL 与 Header 门禁；
- POST 不自动重试，模型发现 GET 只能使用有限重试入口；
- 通过 `BoneInferenceProviderResponseValidator` 映射稳定状态与结构化 safety；
- 不把 Prompt、响应正文、凭据、完整 URL、Cookie 或 Authorization 写入错误、日志、事件和 Harness 报告；
- Streaming 必须在协议完整终态后返回统一 Response，不发布半截 token；
- OpenAI、Gemini、Anthropic 的 Output Constraint 使用各自官方 JSON Schema 字段，不套本地 Prompt Template 或 Tool Envelope；首版不得与 structured `responseFormat` 或 Tool Catalog 混用；
- Schema 必须经过 Provider 方言编译并在响应后本地复验；兼容 Endpoint、未知字段支持或身份漂移均在联网前失败。

## 可读推理披露

`BoneInferenceRequest.reasoningDisclosure` 默认为 `.hidden`。业务只有通过
`BoneInferenceDetailedResultProviding` 或 `BoneInferenceDetailedBufferedStreaming` 才能取得内存中的
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

## MiniMax：显式启用受控 Tool 结构化输出

MiniMax Anthropic 兼容入口只支持 `tool_choice: auto/none`，不支持强制指定结果 Tool。
`nativeOrToolCall` 是允许回退的策略，不是供应商能力保证。默认配置仍在联网前拒绝
MiniMax 的结构化请求；Host 可显式启用单次尝试：

```swift
let engine = BoneAnthropicInferenceEngine(
    configuration: providerConfiguration, // kind: .miniMax
    transport: transport,
    allowsMiniMaxStructuredToolOutput: true
)
let support = try engine.structuredOutputSupport(for: request, invocation: .streaming)
guard support.toolOutput else {
    throw BoneInferenceError.unsupportedStructuredOutput
}
// request.responseFormat 使用 .jsonSchema(schema, fallback: .nativeOrToolCall)
let result = try await engine.inferDetailedUsingStream(request: request, options: .init())
```

查询按实例开关、模型 profile 和调用方式计算：`toolCalling` 为普通 Tool 调用，
`nativeJSONSchema` 为 responseFormat 原生 Schema，`toolOutput` 为受控结果 Tool 适配，
`forcedToolSelection` 为能否强制选择 Tool。MiniMax 的后两项分别为显式启用后的支持值与 false。
该查询属于 `BoneAnthropicInferenceEngine`，并非所有 Provider 的统一能力接口。
它不承诺远端模型成功率，也不替代 Schema 与请求有效性校验。
`outputConstraint` 是另一套约束契约，应继续用 `resolvedCapabilities` 查询。

启用后请求只携带 `submit_structured_result` 结果 Tool，并使用 `tool_choice: auto`。
SDK 只接受恰好一次指定 Tool 调用、Tool 完成状态、无同时正文且本地 Schema 校验通过的结果。
纯文本 JSON、错误 Tool、多次调用、字段不符或不完整结果均不作为成功返回。
`requireNative` 仍拒绝；不能同时传业务 Tools。其他供应商原有文本归一化行为不变。

非流式、缓冲流式、详细结果流式和事件流入口共用严格验收边界，不追加 repair 或重试请求。
取消和传输超时错误继续传播，流式 options 原样传入 transport。
这里不新增预算机制；直接调用 engine 的预算由 Host 管理，不会隐式消耗第二次请求预算。
现有 BoneAgent 只接受 text responseFormat，本次未扩大 Agent 的结构化运行范围。

验证范围为本地 transport 替身和回归测试，未执行 MiniMax 真机/线上 Smoke，
不能据此声明 MiniMax-M3 的实际成功率。上线前应使用无敏感内容的小型 Schema 验证。
协议依据（2026-09-12）：[MiniMax Messages API](https://platform.minimax.io/docs/api-reference/text-chat-anthropic)。

## Agnes：动态模型列表与独立限制

Agnes 目录使用 remote 模式，不再内置文本或图片模型列表。默认 Base URL 仍为
`https://apihub.agnes-ai.cn/v1`；国际站可由 Host 填写 `https://apihub.agnes-ai.com/v1`。
用户配置应为 API Base URL 而非完整 chat endpoint。

```swift
let client = BoneInferenceModelDiscoveryClient(configuration: providerConfiguration)
let models = try await client.discoverAgnesModels()
```

发现请求使用当前 Base URL 下的 `/models`，不固定请求国内域名；失败传播错误，
不回退到已废弃的内置模型。返回值仅提供 ID/名称，不据名称猜测 Tool、视觉能力或 Token 限制。
远端图片模型的协议、画幅等仍需 Host 配置，不能将所有发现结果默认作为聊天模型。

Token 限制复用 `BoneModelContextLimits`（或 `decodeFromExtraConfiguration` 的 `tokenLimits`），
由 Host 按站点与模型单独保存、编辑，再交给 `BoneContextWindowPlanner` 使用。
SDK 不新增持久配置库，也不将同一供应商所有模型套用一个上限。
无证据的限制保持未知，不自动填入 1M/64K；该类型的 source 为 official/gateway，
自定的保守业务预算应作为请求输出预算，而非伪造官方模型能力。
上下文窗口、独立最大输入、最大输出与单次请求预算分别管理；完整输入仍需扣除输出与安全余量。
已有 Host 缓存需自行刷新，不会被 SDK 静默删除或迁移。

## 非流式安全响应诊断

OpenAI（含 Agnes 等兼容入口）、Anthropic 和 Gemini Engine 的 `diagnostics` 参数默认关闭。
它与 Agent Debug 日志独立，不要求开启完整载荷日志：

```swift
let diagnostics = BoneInferenceDiagnosticSink { event in
    // 快速交给 Host 的线程安全指标收集器；不要等待当前推理结束。
    // event.invocationID 是本地关联 UUID，不是服务端请求凭据。
    switch event.phase {
    case .httpResponseReceived:
        if let summary = event.response {
            // statusCode、bodyBytes、stop、toolCount 与 Token 用量均为受限元数据。
            // BoneDiagnosticCount 的 unknown / invalid / value(0) 含义不同。
            _ = summary
        }
    default: break
    }
}
let engine = BoneOpenAIInferenceEngine(
    configuration: providerConfiguration,
    transport: transport,
    diagnostics: diagnostics
)
```

事件顺序为 transportAttempt → httpResponseReceived → resultValidated 或 responseValidationFailed。
未收齐 HTTPResponse 的失败只产生 transportFailed，不补造停止原因和用量。
预检失败没有 transportAttempt；未知停止原因归为 other，原值不记录。
摘要最大处理 1 MiB JSON、最多检查 128 个 Tool/内容块，停止原因最多 64 UTF-8 字节；
超限为 tooLarge 或 invalid，不影响原响应解析的上限与业务行为。
不输出正文、参数、Header、供应商 ID 或错误原始文案，不修改原错误，不增加请求。
wireProtocol 表示所选适配器协议，不表示已经验证响应协议合法。

Host 可按事件分别统计传输接口调用、完整 HTTP 响应和有效结果，不能使用完成步骤数代替。
transportAttempt 只表示调用了一次注入的 send，无法观测自定义 Transport 内部重试或服务端受理，
不能作为计费凭据。本次未提供业务 Tool 执行计数或持久预算存储。
responseValidationFailed 暂时覆盖 HTTP 状态校验、协议及结果校验，尚未细分全部失败阶段。
回调同步且非抛错；Host 回调若阻塞仍会增加时延，应快速返回。

安全诊断当前仅覆盖非流式 infer / inferDetailed；流式摘要尚未接入。总 deadline 和 Agent 流式模式见下文。
关闭 sink 不解析诊断载荷。Agent 日志 context 改为过滤后构造，响应日志编码失败也不影响推理。

## Host 从静态 Agnes 目录迁移

`remote` 是模型目录来源，不是 NewAPI 响应协议。Agnes 使用标准 OpenAI 列表，
应调用 `discoverAgnesModels()`，不要要求 `success: true`；NewAPI 原有校验不要为此放宽。

建议 Host 执行以下显式合并流程：

1. 保留原 Base URL、凭据引用及用户已选模型，按当前站点请求发现。
2. 用“站点身份 + 模型 ID”匹配已保存记录，不仅按显示名匹配。
3. 已有记录仅更新发现状态/名称等目录字段；保留用户预算、协议变体、图片参数、启停和身份。
4. 新记录只保存 ID/名称及来源，不猜 Tool/视觉能力或 Token 限制，不自动启用全部模型。
5. 本次未出现的旧模型标记为未发现，交给用户处理，不直接删除配置。
6. 发现失败保持错误；若展示缓存，应标注缓存时间与失败状态，不作为新发现成功。

SDK 不管理 Host 数据库或目录管理标记。升级测试应覆盖 alpha.13 旧缓存、国际地址、
图片模型参数保留、未知能力及发现失败，并与 NewAPI 专用协议测试独立。

## Agent 显式缓冲流式模式

```swift
let configuration = try BoneAgentConfiguration(
    maximumSteps: 8,
    inferenceMode: .bufferedStreaming(.init(
        firstEventTimeout: 30,
        idleTimeout: 30,
        totalTimeout: 150,
        deadlineUptime: hostDeadlineUptime
    ))
)
```

`hostDeadlineUptime` 为 Host 可选的绝对单调截止时间，必须与
`ProcessInfo.processInfo.systemUptime` 使用同一时基，不是 Unix 时间戳。
默认仍为 nonStreaming。Agent 流式模式必须指定 totalTimeout、deadlineUptime 或 Run 墙钟预算之一，
无整体边界时在发送前拒绝。不支持 BoneInferenceBufferedStreaming 的 Engine 不回退非流式。

URLSession Transport 的总超时从流请求启动计时，Host deadline 与局部总超时取较早边界，
独立于首事件/空闲 watchdog，不因分片到达重置。首事件指第一个完整 SSE 帧；首帧前的零散字节
不会刷新首事件计时；首帧之后非空数据到达会刷新空闲计时。整体期限到达会取消底层任务，
直接 Transport 调用抛 BoneInferenceStreamDeadlineExceeded，Agent 继续沿现有 inferenceFailed 契约映射。
已存在的 Run 墙钟预算以 Run 起点计算并转换剩余期限，不在每个 Tool 回合重置。

Provider 完整聚合与校验成功后才返回 Agent，Tool 仍走原 Schema、授权、预算和执行流水线。
不执行半截 Tool，不隐式重试或回退。自定义 Engine/Transport 必须自行遵守流式 options 和取消，
SDK 无法强制终止不合作的第三方实现。

此模式暂不向 Host 暴露逐片段进度；非流式安全诊断 sink 尚未扩展到流式。
Thinking 服务端控制也未在本次变更中添加。

## 服务端 Thinking 与内容披露独立

`reasoningDisclosure: .hidden` 只处理返回内容，不表示已向服务端关闭 Thinking。
OpenAI Engine 新增实例级 `serverReasoning`，默认 `.providerDefault` 不发送字段。
目前仅支持 Agnes OpenAI 兼容格式的显式 enabled：

```swift
let engine = BoneOpenAIInferenceEngine(
    configuration: providerConfiguration, // kind: .agnes
    transport: transport,
    serverReasoning: .enabled,
    verifiedThinkingModelIDs: ["agnes-2.5-flash"]
)
let supported = try engine.supportedServerReasoning(for: request, invocation: .nonStreaming)
```

Host 应仅将依据官方文档或实际验证确认支持的模型加入集合；集合与当前实例的站点绑定，
不能直接使用整个动态发现列表。更换站点时需重新核验。不按模型名称推断能力。
启用映射为 `chat_template_kwargs: { enable_thinking: true }`，不自动披露返回的推理正文。
默认不发字段；disabled、未经声明的模型、其他供应商上的 enabled 在网络发送前抛
`BoneInferenceUnsupportedServerReasoning`。Agent 沿现有 inferenceFailed 契约映射该错误，
Host 应在启动 Agent 前查询支持情况。

本次没有证据确认 Agnes 的 false/省略字段语义，所以 disabled 暂不开放；不提供预算或强度
映射，不扩展 Anthropic 入口。实例级策略适用于该实例各次调用，如需不同策略应分别构造实例。
本地回归不代表线上成功率或延迟改善；Thinking 不是超时问题的通用修复。
依据（2026-09-13）：https://wiki.agnes-ai.com/en/docs/agnes-25-flash 的 Thinking Mode 示例。
