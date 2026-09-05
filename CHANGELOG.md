# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本采用 SemVer。

## [Unreleased]

### Fixed

- 阶段二：下载启动前登记身份，隔离迟到取消/暂停/完成；Task 与流终止传播到底层 URLSession，按累计字节中止超大响应。
- 下载采用独立暂存路径，失败清理本操作文件，启动清理旧 `.partial.download`；空间预检计入安装复制并防止溢出。
- Llama Session 完整推理单 in-flight，取消身份隔离，unload 等待在途 Runtime 和控制调用排空。

- 阶段一生产硬化：Catalog 和 Store 拒绝特殊模型 ID、非法文件名和模型目录/资产符号链接；保留 `.bone-install-staging` 目录及 `.partial` 临时文件后缀；路径检查不替代 Host 文件系统隔离。
- Store 使用目标卷内专用目录中的独立 staging、完整性校验与原子 rename 发布；提交失败保留旧模型和下载源，同一 Store 的安装、删除和启动清理互斥。不承诺断电持久性。
- 高风险 Tool 在执行开始后抛错返回 `outcomeUnknown`，Receipt 记录/提交未确认返回 `recoveryRequired`；Agent 对应 `toolOutcomeUnknown` / `toolRecoveryRequired`，`collectAll` 不收集这些错误，不继续后继 Tool 或 inference。
- 授权等待态允许取消/失败并清除 ticket；checkpoint 提交前验证。等待授权时直接标记成功被拒绝，需先显式完成授权恢复。

### Migration

- Llama 新增 `BoneLlamaAdapterError.busy`；并发请求由 Host 排队/重试。取消后卸载，原生不合作时 unload 仍需等待。
- Catalog/Store 新保留 `.bone-download-staging` ID，以及 `.partial.download` 文件后缀（含大小写变体）；自定义下载 Transport 必须交付指定 destination，cancel 返回后不得再写文件。
- 下载可用空间预检改为两份 Manifest 大小加安全余量；URLSession 字节限制允许系统当前块的超额，不是零超额磁盘配额。

- Host 对 `BoneWorkflowToolExecutionError` 和 `BoneAgentError` 的穷尽 switch 需处理新增恢复分类；使用原 Effect identity 读取持久事实并 reconcile，不创建新 identity 自动重试。
- Host 为每个模型根目录提供一个 Store 所有者；`cleanIncompleteDownloads()` 仅在没有其他 Store/进程/下载正在使用该根时调用。安装可能临时需要额外一份模型空间，须纳入 Host 磁盘预算。

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
