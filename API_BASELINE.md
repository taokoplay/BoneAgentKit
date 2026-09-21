# BoneAgentKit 公开 API 基线

## 稳定范围

公开 Product：

- `BoneAgentKit`：生产 Agent、Inference、Workflow、Provider 和 Persistence 契约。
- `BoneAgentTesting`：测试 fixture、scripted engine、recorder、assertion、crash harness 和 Host 持久化契约验收套件。
- `BoneAgentLocalModels`：本地模型 Catalog、Artifact、安全下载、断点恢复、安装状态、安全存储、环境快照、运行规划及两阶段 Runtime Probe 契约。
- `BoneAgentLlama`：llama Runtime seam、Probe Backend、canonical Conversation Renderer，以及默认 text-only、可显式扩展 Tool Calling 的 `BoneInferenceEngine`。

最低平台：iOS 13、macOS 13。最低工具链：Swift 5.9。

当前静态回归统计 405 个顶层 public 类型声明（按四个公开 Product 的 `Sources` 文件中行首 `public struct/enum/class/actor/protocol/typealias` 统计）。该数字用于发现意外减少，不等价于完整 ABI 或 source compatibility 证明。

## 1.0 候选关键入口

- `BoneAgent`、`BoneAgentConfiguration`、`BoneAgentKitVersion`
- `BoneInferenceEngine`、`BoneInferenceBufferedStreaming`、`BoneInferenceDetailedBufferedStreaming`、`BoneInferenceEventStreaming`
- `BoneInferenceRequest`、`BoneInferenceMessage`、`BoneInferenceResponse`、`BoneInferenceOutputConstraint`
- `BoneResolvedInferenceCapabilities`、`BoneModelCapabilityProfile`、`BoneModelCapabilityEvidenceSource`
- `BoneAgentRunModelSnapshot`、`BoneAgentModelSnapshotContext`、`BoneAgentModelSnapshotSink`
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

## Alpha.10 迁移提示

- Direct Enum/JSON Probe 现在使用明确唯一目标；本地验证身份使用必需的 `schemaVersion = 3` 与 `probeProtocolVersion = 2`。缺少/错误版本或含旧字段的历史身份严格拒绝，Alpha.9 Smoke 记录必须重新验证。

## Alpha.9 迁移提示

- 删除与 module 同名的 `BoneAgentKit` Facade；Agent 运行统一使用 `BoneAgent`。
- Workflow 公开术语统一为 `BoneWorkflow*`；Persistence、Run record、Checkpoint 与 Agent Step 不保留旧别名。
- 推理调用方式统一为 `BoneInferenceInvocationMode`；聚合式流传输统一使用 `BufferedStreaming`，逐事件入口仍为 `BoneInferenceEventStreaming`。
- Product/module/test target `BoneAgentLocalRuntime` 改为 `BoneAgentLocalModels`；Adapter abstraction 改称 `BoneLocalModelBackend*`。
- 本地验证身份改为 `BoneLocalExecutionVerificationIdentity`，并将 Grammar Parser 与 Grammar Sampler 身份分离；Alpha.9 编码使用必需的 `schemaVersion = 2`，缺少/错误版本或含旧字段的 Alpha.8 本地身份严格拒绝，不能静默映射。
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

## Unreleased 阶段一兼容差异

- 新增 `BoneWorkflowToolExecutionError.outcomeUnknown/recoveryRequired` 与 `BoneAgentError.toolOutcomeUnknown/toolRecoveryRequired`；Host 穷尽 switch 必须迁移，禁止按普通工具失败自动重试。
- `BoneLocalModelStore` 公开构造参数保持不变；测试用提交故障 seam 为 internal。安全例外：拒绝 `.` / `..` 模型 ID 、保留 staging 目录名、`.partial` 资产名和符号链接资产，不保留这些危险输入的旧行为。
- `BoneWorkflowAgentStepController.finish(.succeeded)` 在 waiting 状态拒绝；失败和取消清除授权 ticket，恢复成功路径不变。

## 阶段二安全兼容调整（Unreleased）

- `BoneLlamaAdapterError.busy` 新增；同 Session 不排队，完整请求与卸载排空期间拒绝新 infer。
- 下载 Transport 方法签名不变，但完成 URL 必须等于 request.destinationURL，cancel 返回须停止写入；start 抛错不能留下后台 writer。
- Store/Catalog 保留 `.bone-download-staging` 及资产 `.partial.download` 大小写变体；下载磁盘预算为两份模型加 margin，溢出拒绝。
- Llama cancel 为协作控制，unload 等待在途调用退出；不承诺强制终止原生代码。

## 阶段三兼容调整（Unreleased）

- BoneAgent initializer 追加默认 `monotonicClock: @Sendable () -> TimeInterval`；普通初始化源码兼容，不承诺函数引用/预编译二进制兼容。
- 原子 turn/tool execution reserve 为 internal；公开 Meter 方法与预算错误枚举不变。
- OpenAI 普通文本也必须单 choice、stop；流式另需 DONE。length → outputTruncated，过滤/拒绝/缺失/未知终态 → invalidResponse。保留 requiringSingleCompletedChoice 参数但不再允许宽松模式。
- SSE 未成帧 EOF 返回 invalidResponse；LF/CRLF 及逐字节 UTF-8 保留，未扩展 CR-only/BOM/Last-Event-ID。
- BoneAgent 两个 initializer 及 `run(modelID:messages:)`、`run(request:)`、`runUntilBoundary(request:boundary:)`、`runWorkflowStep(modelID:messages:controller:)` 追加默认 `snapshotContext:` 与 `modelSnapshotSink:`；带标签调用源码兼容。
- 追加默认参数后旧签名不再是协议 witness：把 `run(modelID:messages:)` 等签名抽成协议并要求 `BoneAgent` 满足的调用方需同步更新协议要求。
- 模型快照在返回值或错误抛出之前投递；能力门禁之前的拒绝不产出快照。


## Host 持久化契约测试 API

`BoneAgentTesting` 新增 `BoneWorkflowPersistenceContractSuite`、`BoneWorkflowPersistenceContractFixture`、`BoneWorkflowPersistenceContractFixtureFactory`、`BoneWorkflowPersistenceContractCase`、`BoneWorkflowPersistenceContractObservation`、`BoneWorkflowPersistenceContractOutcome`、`BoneWorkflowPersistenceContractFailure` 和 `BoneWorkflowPersistenceContractCapability`。

`run(factory:) async throws` 返回固定白名单 observations；fixture 提供 Store、cleanup 和可选的 reopen/独立连接回调。八个场景的 passed 仅代表相应行为探测通过，skipped 必须单独处理；取消抛出 CancellationError，原始 Host 错误不进入报告。Core Persistence API 与租约语义保持不变。

## Unreleased 正确性修复兼容说明

- 新增 `BoneWorkflowAgentStepController.requireRecovery()` 与 `BoneWorkflowAgentStepEventKind.recoveryRequired`；事件穷尽 switch 需更新。
- Controller 提交异常/无效回执后禁止继续写入；直接调用保留 Store 错误，标准 progress sink 报 `toolRecoveryRequired`。Host 重读后重建，不把未确认提交当作普通业务失败。
- Gemini call ID 仍为 String，但 fallback 不再跨轮重复；opaque continuation 的累计格式为 Provider 私有实现，不构成稳定解码接口。

## Unreleased P0 持久化契约澄清

- Core 协议签名及参考实现行为不变：payload 是合法 JSON 的业务 schema 不透明字节；create 接受并保存任意 UInt64 generation，acquireLease 是非幂等 CAS 换代。详细边界见 [Workflow 与恢复](Documentation/WorkflowAndRecovery.md)。
- `BoneWorkflowPersistenceContractCase` 新增 `opaqueCheckpointPayload` / `creationLeaseGeneration`，allCases 从 6 增至 8；工厂穷尽 switch 与固定数量断言需要更新。可选 capability 枚举不变，不提供 opaque payload 跳过能力。
- `BoneWorkflowPersistenceContractFailure` 新增 `seedCreateRejected` / `seedLoadFailed` / `opaquePayloadRejected` / `creationGenerationRejected`，穷尽 switch、报告消费者与差距守卫需要同步。它们按失败阶段分类，不宣称识别 Host 私有 schema 或底层故障根因。

## Unreleased P1 Run 控制面

- 新增 `BoneWorkflowRunController`，以组合方式提供 create/bind/begin/pause/resume/recover/requestCancellation/stopRequestedExecution/reconcileTerminal；不改变既有 Persistence 协议、Run 状态表或 Effect Store 接口。
- 新增 `BoneWorkflowRunControllerContractSuite`、`BoneWorkflowRunControllerContractCase`、`BoneWorkflowRunControllerContractFailure`、`BoneWorkflowRunControllerContractObservation`，五项必需场景，无 skipped。factory 复用 `BoneWorkflowPersistenceContractFixture`，但场景枚举不同。
- 控制器方法要求显式 expectedRevision，Worker 停止与终态协调还要求 leaseGeneration；begin/resume 必须换代，pause 也换代。Host 接入后必须使用返回 snapshot 的新 revision/generation 绑定 Worker 与 Effect，不能继续使用旧令牌。
- 请求取消返回 cancelling snapshot，而不是“执行已停止”的 Bool；Host 需要停止/对账后显式 reconcileTerminal。业务绑定、索引、扫描、授权、外部预算与 Worker 生命周期仍归 Host。

## Unreleased P2 恢复扫描与索引边界

- 新增可选 `BoneWorkflowRecoveryScan` / `BoneWorkflowRecoveryScanResult`，内存参考实现新增 conformance；原 Persistence 四方法、Run Controller API 均不变。
- 新增 `BoneWorkflowRecoveryScanContractSuite`、`BoneWorkflowRecoveryScanContractFixture`、`BoneWorkflowRecoveryScanContractCase`、`BoneWorkflowRecoveryScanContractFailure`、`BoneWorkflowRecoveryScanContractCapability`、`BoneWorkflowRecoveryScanContractOutcome`、`BoneWorkflowRecoveryScanContractObservation`。
- 扫描为固定授权 scope 的完整一致快照，无分页和静默截断。包括 recoveryRequired 以支持人工调和，但不授权重新执行；隔离数为当前不可用记录计数，不是累计错误数。
- 业务实体反查、唯一非终态约束、生命周期与 Run＋实体原子创建留在 Host，推荐 seam 与事务要求见 [Workflow 与恢复](Documentation/WorkflowAndRecovery.md)。

## Unreleased P3 取消安全判定

- 新增 `BoneWorkflowCancellationReadinessQuery`、`BoneWorkflowCancellationSnapshot`（嵌套 Session/Effect/Checks）、`BoneWorkflowCancellationReadiness`、`BoneWorkflowCancellationEvaluation`、`BoneWorkflowCancellationDecision`、`BoneWorkflowCancellationRejection`。
- 新增 `BoneWorkflowCancellationReadinessContractSuite`、`BoneWorkflowCancellationReadinessContractFixture`、`BoneWorkflowCancellationReadinessContractCase`、`BoneWorkflowCancellationReadinessContractFailure`、`BoneWorkflowCancellationReadinessContractObservation`；十一个必需场景无 skipped。
- 只读能力，无生产写入 API、无自动终态、无完整 session 存储。evaluation 绑定 Run revision/generation 与全事实 evidenceRevision，Host 必须在收口事务复核；不改变 RunController/Persistence/EffectStore 既有接口。

## Unreleased P4 持久预算

- 新增 `BoneWorkflowRunBudget`（嵌套 Policy/Clock/Phase/Rejection/Decision/Reservation）、`BoneWorkflowRunBudgetError`、`BoneWorkflowRunBudgetStore`、`BoneInMemoryWorkflowRunBudgetStore`。
- 新增 `BoneWorkflowRunBudgetContractSuite` / Fixture / Case / Failure / Outcome / Observation 六个完整前缀类型，七场景，重开能力缺失明确 skippedReopen。
- 既有 `BoneRunBudget` 与 `BoneRunBudgetMeter` 不变。新持久预算以 Run 为键，open 不重置，reserve 是 revision CAS；used 库存与 attempted 失败尝试分别计数，final 保留不可被普通拒绝耗尽。
- durable 截止在达到任一 deadline 时拒绝（>=），时钟异常/截止永久阻塞。同Run policy/version必须完全一致；更换version不授权修改已有预算。预算编码 schemaVersion=1，解码执行验证，不承诺防恶意篡改。

## Unreleased P5 工作单元账本

- 新增 `BoneWorkflowWorkLedger`（嵌套 Seed/Unit/Page/State/Preflight/Command）、`BoneWorkflowWorkLedgerError`、`BoneWorkflowWorkLedgerStore`、`BoneInMemoryWorkflowWorkLedgerStore`。
- 新增 `BoneWorkflowWorkLedgerContractSuite` / Fixture / Case / Failure / Observation 五个完整前缀类型，七场景无 skipped。
- Run 级 aggregate revision/generation CAS；page 是预留请求尝试序号而非成功结果页数，knownFailure 不回退页号；split 父与子原子保存。opaque Data 单项4MiB。
- 账本无任意状态 Codable 恢复入口；Seed/Command 编码后仍须验证重放，Host 负责版本化日志/存储。旧代在途页不自动转交/重放；显式恢复采用下述独立对账能力。既有 Run/Budget/Effect API 不变。

## Unreleased P6 执行会话与continuation

- 新增 `BoneWorkflowExecutionSession`、`BoneWorkflowExecutionSessionError`、`BoneWorkflowSessionLedger`、`BoneWorkflowExecutionSessionStore`、`BoneInMemoryWorkflowExecutionSessionStore`。
- 新增 `BoneWorkflowExecutionSessionContractSuite` / Fixture / Case / Failure / Observation 五个完整前缀类型，五场景无 skipped。
- admission 为有界不透明 Data，admissionHash 对原始字节SHA256；零基序列、一次性nonce、permit消费与session创建采用ledger CAS。prepare/consume/revoke 的nonce墓碑保留，Command不Codable，Ledger编码不含nonce原文。
- Hash/nonce不是业务授权或Run lease；Host需在消费事务复核可变化事实。不重置P4预算、不复活Run终态；P5跨代对账独立于session API。Session/Ledger schemaVersion=1，解码重验，不承诺抗存储回滚。

## Unreleased P5 补齐：跨代工作页对账

- 新增可选 `BoneWorkflowWorkReconciliationStore`，不修改原 Store 的必需方法；内存参考增加 conformance。
- 新增嵌套 `BoneWorkflowWorkLedger.Reconciliation` / Outcome、纯 `reconciling` 和 Page.reconciliation 审计记录。精确目标+旧代/当前代+aggregate revision绑定；保留原页代、nextPage与计数。
- 新增 `BoneWorkflowWorkReconciliationContractSuite` / Fixture / Case / Failure / Observation，八场景必需，无 skipped。
- Host提交明确knownFailure/committed，不能用未知结果或缺Worker证明失败；已记录响应不可替换。证据引用不认证业务授权，不自动跨Store提交或重发请求。
