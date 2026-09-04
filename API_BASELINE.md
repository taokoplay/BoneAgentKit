# BoneAgentKit 公开 API 基线

## 稳定范围

公开 Product：

- `BoneAgentKit`：生产 Agent、Inference、Workflow、Provider 和 Persistence 契约。
- `BoneAgentTesting`：测试 fixture、scripted engine、recorder、assertion 和 crash harness。
- `BoneAgentLocalModels`：本地模型 Catalog、Artifact、安全下载、断点恢复、安装状态、安全存储、环境快照、运行规划及两阶段 Runtime Probe 契约。
- `BoneAgentLlama`：llama Runtime seam、Probe Backend、canonical Conversation Renderer，以及默认 text-only、可显式扩展 Tool Calling 的 `BoneInferenceEngine`。

最低平台：iOS 13、macOS 13。最低工具链：Swift 5.9。

当前静态回归统计 320 个顶层 public 类型声明（按四个公开 Product 的 `Sources` 文件中行首 `public struct/enum/class/actor/protocol/typealias` 统计）。该数字用于发现意外减少，不等价于完整 ABI 或 source compatibility 证明。

## 1.0 候选关键入口

- `BoneAgent`、`BoneAgentConfiguration`、`BoneAgentKitVersion`
- `BoneInferenceEngine`、`BoneInferenceBufferedStreaming`、`BoneInferenceDetailedBufferedStreaming`、`BoneInferenceEventStreaming`
- `BoneInferenceRequest`、`BoneInferenceMessage`、`BoneInferenceResponse`、`BoneInferenceOutputConstraint`
- `BoneResolvedInferenceCapabilities`、`BoneModelCapabilityProfile`、`BoneModelCapabilityEvidenceSource`
- `BoneLocalExecutionVerificationIdentity`、`BoneProviderCapabilityVerificationIdentity`、`BoneInferenceInvocationMode`
- `BoneLiveConstraintSmoke`、`BoneLiveConstraintSmokeReport`、`BoneLiveConstraintSmokeFailure`
- `BoneAgentTool`、`BoneAgentToolDefinition`、`BoneAgentToolRegistry`
- `BoneWorkflowPlan`、`BoneWorkflowCheckpoint`、`BoneWorkflowPersistence`
- `BoneOpenAIInferenceEngine`、`BoneAnthropicInferenceEngine`、`BoneGeminiInferenceEngine`
- `BoneLocalModelCatalog`、`BoneLocalModelStore`、`BoneLocalRuntimePlanner`
- `BoneLocalModelDownloadCoordinator`、`BoneLocalModelDownloadTransport`、`BoneURLSessionLocalModelDownloadTransport`
- `BoneLocalModelArtifactInspector`、`BoneLocalRuntimeProbeCoordinator`、`BoneLocalModelBackendDescriptor`、`BoneLocalModelBackendProbing`
- `BoneLlamaRuntime`、`BoneLlamaRuntimeStateObserving`、`BoneLlamaRuntimeState`、`BoneLlamaModelState`
- `BoneLlamaPromptTokenization`、`BoneLlamaPromptExecutionPlan`、`BoneLlamaPromptExecutionPlanner`
- `BoneLlamaConversation`、`BoneLlamaConversationRendering`、`BoneLlamaChatMLConversationRenderer`、`BoneLlamaNativeTemplateRenderer`
- `BoneToolSchemaCanonicalEncoder`、`BoneLlamaGenerationControlCanonicalizer`
- `BoneLlamaGenerationControl`、`BoneLlamaControlledGenerationRuntime`、`BoneLlamaConstraintGenerationRuntime`、`BoneLlamaGenerationTermination`
- `BoneLlamaCompiledConstraint`、`BoneLlamaResolvedGenerationControl`、`BoneLlamaConstraintCompiling`、`BoneLlamaGBNFCompiler`
- `BoneLlamaStopMatcher`、`BoneLlamaTerminationValidator`、`BoneLlamaNativeTemplateCapabilities`
- `BoneLlamaRuntimeProbeAdapter`、`BoneLlamaToolEnvelopeCoding`、`BoneLlamaConstrainedJSONToolEnvelopeCodec`、`BoneLlamaInferenceEngine`

## Alpha.9 迁移提示

- 删除与 module 同名的 `BoneAgentKit` Facade；Agent 运行统一使用 `BoneAgent`。
- Workflow 公开术语统一为 `BoneWorkflow*`；Persistence、Run record、Checkpoint 与 Agent Step 不保留旧别名。
- 推理调用方式统一为 `BoneInferenceInvocationMode`；聚合式流传输统一使用 `BufferedStreaming`，逐事件入口仍为 `BoneInferenceEventStreaming`。
- Product/module/test target `BoneAgentLocalRuntime` 改为 `BoneAgentLocalModels`；Adapter abstraction 改称 `BoneLocalModelBackend*`。
- 本地验证身份改为 `BoneLocalExecutionVerificationIdentity`，并将 Grammar Parser 与 Grammar Sampler 身份分离；编码使用必需的 `schemaVersion = 2`，缺少/错误版本或含旧字段的 Alpha.8 本地身份严格拒绝，不能静默映射。
- Constraint Runtime/control 改为 `BoneLlamaConstraintGenerationRuntime` 与 `BoneLlamaResolvedGenerationControl`。
- 删除旧 Prompt Encoder 与组合 Tool Calling 管线；统一使用 canonical Conversation Renderer + Tool Envelope。
- Alpha.9 是预发布 clean break，不提供旧 public typealias、Product 或 initializer；编译错误构成调用方迁移清单。

## 兼容承诺

- 1.0 前允许在 CHANGELOG 和迁移说明完整的前提下调整 API。
- 1.0 后遵循 SemVer；补丁版本不得删除公开符号或收紧合法输入。
- 保留聚合 Product 和现有 `import BoneAgentKit` 接入方式。
- 合法旧 assistant 文本消息继续读取；非法冲突 payload 不属于兼容输入。
- Package target 拆分前必须先通过旧客户端编译 fixture。

## 弃用周期

- 1.0 后公开 API 先标记 deprecated，并提供 renamed 或迁移说明。
- 1.0 后默认至少跨一个 minor 版本保留弃用入口；计划移除必须进入下一个 major 版本。
- Alpha 阶段可在 CHANGELOG 与迁移说明完整时执行 clean break；Alpha.9 明确不保留旧别名。
- 安全漏洞例外必须在 CHANGELOG 中说明影响、替代方案和紧急处理理由。

## 非承诺范围

- Provider 私有 wire DTO、Header、原始响应和内部 controller 不属于公开稳定接口。
- 模型具体能力由实例和请求解析，不按 Provider 名称永久承诺。
- llama.cpp 与 Foundation Models adapter 在独立 preview 版本稳定前不属于 1.0 必选依赖。
