# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本采用 SemVer。

## [Unreleased]

## [0.2.0-alpha.9] - 2026-09-04

### Changed

- 删除与 module 同名的 `BoneAgentKit` Facade，`BoneAgent` 成为唯一 Agent 运行入口；Workflow 类型统一为 `BoneWorkflow*`。
- 合并两套 Invocation 概念为 `BoneInferenceInvocationMode`，并用 `BufferedStreaming` 区分聚合式流传输与逐事件 Streaming。
- Product/module/test target `BoneAgentLocalRuntime` 改为 `BoneAgentLocalModels`，Probe Adapter abstraction 改为 `BoneLocalModelBackend*`。
- 本地能力证据改为 `BoneLocalExecutionVerificationIdentity`；Grammar Parser 与 Grammar Sampler 分别绑定身份，任一漂移都会撤销高级能力。该身份使用必需的 `schemaVersion = 2` 和严格自定义解码；缺少版本、版本不匹配或包含 Alpha.8 `constraintDecoder*` / `grammarRuntime*` 字段的旧身份一律拒绝，不能静默复用。
- Llama Constraint seam 改为 `BoneLlamaConstraintGenerationRuntime` 与 `BoneLlamaResolvedGenerationControl`；删除旧 Prompt Encoder 和组合 Tool Calling 管线，只保留 canonical Conversation Renderer + Tool Envelope。
- 测试术语改为 `BoneCrashBoundaryHarness` / `boundaryVisited`，基础 Runtime 检查改为 `verifyBasicGeneration()`。
- 本次为 1.0 前 clean break，不保留旧 public typealias、Product/module 或 initializer；保持 Invocation 的 `nonStreaming` / `streaming` Codable raw values 不变。

## [0.2.0-alpha.8] - 2026-09-04

### Added

- 新增显式版本化的 `BoneToolSchemaCanonicalEncoder` 与 Llama Generation Control canonical identity，替代 `String(describing:)`，并避免在身份中保存 Stop、Schema、Grammar 或输出正文。
- 新增受信任的 `BoneLlamaCompiledConstraint`、`BoneLlamaGBNFCompiler` 与 `BoneLlamaCompiledConstraintRuntime`；支持精确 Enum 以及 boolean、无范围 integer/number、无长度 string/enum、无界 array、required-only closed object 和受限 tagged union。
- 新增 UTF-8 增量 Stop Matcher，支持跨 chunk、多字节字符、重叠与前缀 Stop；Generation termination 现在携带实际 Stop Token ID 或 Stop String index。
- Canonical Llama Engine 现可将请求级 `outputConstraint` 编译后交给真实 Grammar Runtime，并在返回后再次执行逐字节 Enum 或完整 JSON Schema 验证。
- Runtime Smoke 现覆盖 constrained Tool 两轮、直接 Enum 与 JSON 输出，并将 Compiler、Canonical 格式、Grammar Runtime、Stop Matcher 和 Termination contract 绑定到执行身份。
- Native Template Runtime 新增 reasoning mode 与 add-generation-prompt 能力协商。

### Changed

- Llama constraint 请求不再允许旧 `BoneLlamaControlledGenerationRuntime` 解释 Schema；必须实现 `BoneLlamaCompiledConstraintRuntime`。Stop-only 请求仍可沿用旧协议。
- `BoneLlamaGenerationTermination.stopToken` / `.stopString` 改为带证据的 `stopToken(id:)` / `stopString(index:)`。Constraint 和 Tool Envelope 继续拒绝截断或模糊的 `runtimeCompleted`。
- Alpha.8 GBNF 首版对 optional properties、开放 `additionalProperties`、字符串/数组长度和数值范围前置拒绝，不做 prompt-only 或宽松降级。

## [0.2.0-alpha.7] - 2026-09-03

### Added

- 新增请求级 `BoneInferenceOutputConstraint` 与 `.constrainedOutput` 能力门禁；未实现约束输出的 Engine 必须在 Provider/Runtime 调用前拒绝，不能静默忽略。
- 新增模板无关的 Llama Conversation、唯一 Renderer、GGUF Native Template Runtime seam，以及显式 Stop/EOG、生成约束和终止原因契约。
- 新增严格判别联合的 `BoneLlamaConstrainedJSONToolEnvelopeCodec`，动态约束当前 Tool Catalog，并在生成后继续执行 Tool、参数 Schema 和调用 ID 校验。
- 新增绑定 Artifact、Runtime、Tokenizer、Template、Generation Control、Tool Envelope、Constraint Decoder 与 Context/Batch 的 `BoneCapabilityVerificationIdentity`。
- 新增云 Provider 专用 `BoneProviderCapabilityVerificationIdentity`、`.providerSmoke` 证据来源及安全的 `BoneLiveConstraintSmoke` 聚合报告；身份绑定 Provider、协议、Endpoint 摘要、API、精确模型、Mapper/Decoder、Constraint 方言和调用模式。
- 新增 OpenAI Chat Completions、Gemini GenerateContent 与 Anthropic Messages 的原生请求级 Output Constraint Adapter；统一使用严格包装 Schema，并在 SDK 边界复验和还原结果。

### Changed

- `BoneLlamaInferenceEngine` 新增 canonical `Build → Render → Tokenize → Plan → Generate → Decode` 路线；alpha.6 的 Prompt Encoder/Tool Calling 初始化入口继续兼容。
- Llama Runtime Probe 可执行受约束 Tool Call 与 Tool Result 续轮 Smoke；截断、模糊终止原因、reasoning 标记、缺少受控 Runtime 或验证身份均失败关闭。Engine 只有在当前 Runtime 身份与 Profile 精确匹配时才保留高级本地能力。
- ChatML Renderer 使用稳定模板 SHA-256，并拒绝消息正文中的保留模板 Token；云端受约束事件流在完整复验前不发布 tentative 正文。
- Live Provider Smoke CLI 改为严格互斥参数解析、精确单变量凭据读取和安全模型 ID 白名单；Provider 身份同时绑定认证模式与脱敏后的语义 Header 配置。
- `.runtimeSmoke` 若要证明 `.toolCalling` 或 `.constrainedOutput`，必须携带完整本地 Runtime 验证身份；`.providerSmoke` 若要证明云端 `.constrainedOutput`，必须携带匹配的 Provider 验证身份。
- `outputConstraint` 首版不能与 structured `responseFormat` 或非空 Tool Catalog 混用；Enum 逐字节精确匹配，JSON Schema 结果不做裁剪、提取或修复。
- 云 Provider 只有官方 kind、受支持方言和精确 Smoke 身份同时匹配时才动态授予 `.constrainedOutput`；兼容端点、仅官方文档证据、流式模式或执行身份漂移均在联网前失败。Bundled Catalog 尚未写入真实 Provider Smoke 身份，因此默认能力不自动启用。

## [0.2.0-alpha.6] - 2026-09-02

### Added

- 新增真实 Tokenizer 驱动的 `BoneLlamaPromptExecutionPlan` 与自动 prefill Token ranges；Prompt 可以安全跨多个 decode batch，输出上限会按剩余 Context 自动收紧。

### Changed

- 收紧 `BoneLlamaRuntime`：Runtime 必须实现真实 `tokenize(prompt:)`，并按 Engine 传入的 execution plan 分片 prefill；Context 超限在原生 decode 前映射为 `.promptTooLong`。

## [0.2.0-alpha.5] - 2026-09-02

### Added

- `BoneLlamaInferenceEngine` 支持显式注入 `BoneLlamaToolCalling` 后按实例声明 `.toolCalling`；新增严格 ChatML + JSON envelope 的 `BoneLlamaJSONToolCallingCodec`，覆盖 Tool schema、并行调用和 Tool Result 续轮，默认仍为 text-only。
- 新增 `BoneModelCapabilityProfile` 与证据来源，供云端 Provider Catalog 和本地模型 Descriptor 可选声明细粒度推理能力；本地 Probe 报告实际验证的 `.text` / `.toolCalling` 能力。

### Changed

- Provider 与 Llama Engine 在模型 Profile 已知时将其与实现能力取交集；`BoneAgent` 在 `runStarted` 前改用请求级 `resolvedCapabilities` 预检。
- 新增公开 `BoneAgentKitVersion` 运行时版本镜像，并通过测试约束 README 与 CHANGELOG 的版本一致性；SwiftPM 发布版本仍以 Git Tag 为准。

## [0.2.0-alpha.4] - 2026-09-01

### Changed

- README 重构为开源 SDK 门面，统一 Product、安装、能力、架构、限制与许可层级；新增分类文档地图。
- 扩展公开说明门禁，检查项目专有术语、本机路径、README 契约、Markdown 相对链接和标题层级。

## [0.2.0-alpha.3] - 2026-09-01

### Changed

- 公开说明改为通用 App Host 边界，不再包含任何调用项目名称或 Host 专有实现细节。

## [0.2.0-alpha.2] - 2026-09-01

### Changed

- BoneAgentKit 源码和文档从 proprietary 许可切换为 `AGPL-3.0-only`。
- Provider 渠道 PNG 与其中涉及的第三方商标明确排除在 AGPL 授权范围外；历史 tag 的许可不追溯变更。

## [0.2.0-alpha.1] - 2026-09-01

### Added

- 新增 `BoneAgentLocalRuntime` Product，提供本地模型 Catalog、多下载源 Artifact、安全安装存储、环境快照与确定性运行规划。
- 新增 actor 下载 Coordinator、可注入 Transport 和默认 URLSession Transport，支持磁盘预检、可信重定向、进度、暂停/恢复/取消及受控多源切换。
- 新增本地模型 Artifact Inspector、Adapter Probe 契约和 metadata/load/smoke 两阶段 Probe Coordinator。
- 新增 `BoneAgentLlama` Product，提供无二进制耦合的 Runtime seam、load/smoke Probe、通用 ChatML encoder 与 text-only `BoneInferenceEngine`。
- `BoneLlamaInferenceEngine` 提供当前模型状态快照和 AsyncStream 实时通知；可选 `BoneLlamaRuntimeStateObserving` 供具体 Runtime 暴露加载、生成、取消、卸载与失败状态。
- `BoneAgentKit` 内置 14 个 Provider 渠道的 42 个 1x/2x/3x PNG，资源实现 Target 不作为独立 Product 暴露。
- `BoneInferenceProviderCatalog.iconData(iconID:scale:)` fail-closed 资源接口与完整性测试。
- Host compatibility manifest。
- 实例与请求级 `BoneResolvedInferenceCapabilities`。
- BoneAgentKit 现代化基线和发布契约。

### Changed

- 推理消息解码改为显式 one-of 校验，同时兼容旧 assistant 文本消息。
- Custom OpenAI-compatible endpoint 不再默认承诺原生结构化输出。
- `.commitUncertain` 可恢复，但禁止自动继续或重试。

### Fixed

- Swift 6 strict concurrency 测试阻断。
- Workflow Step controller 交错运行的身份回归覆盖。
- `BoneInferenceHTTPTransport` 文档边界回归。

## 版本列车

### 0.x-hardening

只交付正确性、恢复语义、安全、严格并发和分发治理；不切换 Host 默认行为。

### 0.x-modularization

只交付 target 拆分与兼容入口；不同时启用 managed context 或本地 Runtime。

### 1.0.0

仅在 hardening、modularization、法律审计、真实 Provider Smoke 和宿主兼容门禁全部通过后签发。
