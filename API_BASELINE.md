# BoneAgentKit 公开 API 基线

## 稳定范围

公开 Product：

- `BoneAgentKit`：生产 Agent、Inference、Workflow、Provider 和 Persistence 契约。
- `BoneAgentTesting`：测试 fixture、scripted engine、recorder、assertion 和 crash harness。
- `BoneAgentLocalRuntime`：本地模型 Catalog、Artifact、安全下载、断点恢复、安装状态、安全存储、环境快照、运行规划及两阶段 Runtime Probe 契约。
- `BoneAgentLlama`：llama Runtime seam、Probe Adapter、Prompt encoder，以及默认 text-only、可显式扩展 Tool Calling 的 `BoneInferenceEngine`。

最低平台：iOS 13、macOS 13。最低工具链：Swift 5.9。

当前静态回归统计 328 个顶层 public 类型声明（按 `Sources` 中四个公开 Product 及安全 Smoke executable 共用源码的 `public struct/enum/class/actor/protocol/typealias` 统计）。该数字用于发现意外减少，不等价于完整 ABI 或 source compatibility 证明。

## 1.0 候选关键入口

- `BoneAgent`、`BoneAgentKit`、`BoneAgentConfiguration`、`BoneAgentKitVersion`
- `BoneInferenceEngine`、`BoneInferenceStreaming`
- `BoneInferenceRequest`、`BoneInferenceMessage`、`BoneInferenceResponse`、`BoneInferenceOutputConstraint`
- `BoneResolvedInferenceCapabilities`、`BoneModelCapabilityProfile`、`BoneModelCapabilityEvidenceSource`
- `BoneCapabilityVerificationIdentity`、`BoneProviderCapabilityVerificationIdentity`、`BoneInferenceInvocationIdentity`
- `BoneLiveConstraintSmoke`、`BoneLiveConstraintSmokeReport`、`BoneLiveConstraintSmokeFailure`
- `BoneAgentTool`、`BoneAgentToolDefinition`、`BoneAgentToolRegistry`
- `BoneWorkflowPlan`、`BoneRunCheckpoint`、`BoneAgentPersistence`
- `BoneOpenAIInferenceEngine`、`BoneAnthropicInferenceEngine`、`BoneGeminiInferenceEngine`
- `BoneLocalModelCatalog`、`BoneLocalModelStore`、`BoneLocalRuntimePlanner`
- `BoneLocalModelDownloadCoordinator`、`BoneLocalModelDownloadTransport`、`BoneURLSessionLocalModelDownloadTransport`
- `BoneLocalModelArtifactInspector`、`BoneLocalRuntimeProbeCoordinator`、`BoneLocalRuntimeAdapterProbing`
- `BoneLlamaRuntime`、`BoneLlamaRuntimeStateObserving`、`BoneLlamaRuntimeState`、`BoneLlamaModelState`
- `BoneLlamaPromptTokenization`、`BoneLlamaPromptExecutionPlan`、`BoneLlamaPromptExecutionPlanner`
- `BoneLlamaConversation`、`BoneLlamaConversationRendering`、`BoneLlamaChatMLConversationRenderer`、`BoneLlamaNativeTemplateRenderer`
- `BoneToolSchemaCanonicalEncoder`、`BoneLlamaGenerationControlCanonicalizer`
- `BoneLlamaGenerationControl`、`BoneLlamaControlledGenerationRuntime`、`BoneLlamaCompiledConstraintRuntime`、`BoneLlamaGenerationTermination`
- `BoneLlamaCompiledConstraint`、`BoneLlamaCompiledGenerationControl`、`BoneLlamaConstraintCompiling`、`BoneLlamaGBNFCompiler`
- `BoneLlamaStopMatcher`、`BoneLlamaTerminationValidator`、`BoneLlamaNativeTemplateCapabilities`
- `BoneLlamaRuntimeProbeAdapter`、`BoneLlamaToolEnvelopeCoding`、`BoneLlamaConstrainedJSONToolEnvelopeCodec`、`BoneLlamaInferenceEngine`

## Alpha.8 迁移提示

- `BoneLlamaGenerationTermination.stopToken` 与 `.stopString` 改为带证据的 `stopToken(id:)` 与 `stopString(index:)`，Runtime 实现和 switch pattern 需要迁移。
- `BoneLlamaNativeTemplateRenderingRuntime` 新增 `nativeTemplateCapabilities()` 要求；Runtime 必须在实际模板渲染前声明 reasoning mode 与 generation prompt 支持。
- Constraint 请求改走 `BoneLlamaCompiledConstraintRuntime`；旧 `BoneLlamaControlledGenerationRuntime` 仅继续承载 Stop-only 兼容路径。
- `BoneCapabilityVerificationIdentity` 新增字段均为可选以保持旧 Profile 解码兼容，但缺少完整 Constraint Runtime 身份时不能授予 `.constrainedOutput`。

## 兼容承诺

- 1.0 前允许在 CHANGELOG 和迁移说明完整的前提下调整 API。
- 1.0 后遵循 SemVer；补丁版本不得删除公开符号或收紧合法输入。
- 保留聚合 Product 和现有 `import BoneAgentKit` 接入方式。
- 合法旧 assistant 文本消息继续读取；非法冲突 payload 不属于兼容输入。
- Package target 拆分前必须先通过旧客户端编译 fixture。

## 弃用周期

- 公开 API 先标记 deprecated，并提供 renamed 或迁移说明。
- 默认至少跨一个 minor 版本保留弃用入口；计划移除必须进入下一个 major 版本。
- 安全漏洞例外必须在 CHANGELOG 中说明影响、替代方案和紧急处理理由。

## 非承诺范围

- Provider 私有 wire DTO、Header、原始响应和内部 controller 不属于公开稳定接口。
- 模型具体能力由实例和请求解析，不按 Provider 名称永久承诺。
- llama.cpp 与 Foundation Models adapter 在独立 preview 版本稳定前不属于 1.0 必选依赖。
