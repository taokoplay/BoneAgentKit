# Swift Package 接入

## 当前形态

BoneAgentKit 通过独立 Git 仓库中的 Swift Package 分发。调用方应使用明确版本或精确 revision，并只链接实际需要的 Product。

```swift
.package(
    url: "https://github.com/taokoplay/BoneAgentKit.git",
    exact: "<approved-version>"
)
```

基础调用方只需依赖 `BoneAgentKit`；本地模型基础设施和 Adapter 是独立 Product，不会因基础依赖自动启用。

Git Tag 是 SwiftPM 依赖解析的版本事实源。`BoneAgentKitVersion.current` 是供日志、诊断和兼容检查使用的运行时镜像，不会替代或自动创建 Tag；每次发布必须同步更新源码常量、README、CHANGELOG 与 Tag。当前预发布版本为 `0.2.0-alpha.23`。

从 `0.2.0-alpha.5` 升级时，使用方的 `BoneLlamaRuntime` 实现必须适配新的真实 Token 容量契约：增加 `tokenize(prompt:)`，并将旧 `generate(prompt:options:)` 改为 `generate(prompt:executionPlan:options:)`。Runtime 必须按 `executionPlan.prefillRanges` 对完整 Prompt 的 Token IDs 分批 prefill；完整迁移要求见 [LocalModels.md](LocalModels.md#从-alpha5-迁移到-alpha6)。只使用云 Provider 或未链接 `BoneAgentLlama` 的调用方不受该协议变更影响。

当前预发布开发线提供完整的本地 Constraint Runtime 闭环。Alpha.9 已删除 `promptEncoder` / `toolCalling` 旧初始化入口；调用方必须使用 `conversationRenderer` + `toolEnvelope`。Native Template Runtime 必须通过 `nativeTemplateCapabilities()` 声明 reasoning mode 与 add-generation-prompt 支持。Stop-only 可继续实现 `BoneLlamaControlledGenerationRuntime`；请求级 Constraint 和受约束 Tool Envelope 必须实现 `BoneLlamaConstraintGenerationRuntime`，并把 SDK 的 compiled artifact 接入实际 Grammar Sampler。用于高级 Smoke 身份时还应实现 `BoneLlamaRuntimeVerificationIdentifying`。未实现对应协议时必须失败关闭，不会静默降级。

同一开发线也为官方 OpenAI、Gemini 和 Anthropic 增加请求级原生 Output Constraint seam。调用方只设置 `BoneInferenceRequest.outputConstraint`，不得同时设置 structured `responseFormat` 或非空 Tools。Engine 只有在精确模型的 `.providerSmoke` Profile 包含与当前 Provider、Endpoint 摘要、API、Mapper/Decoder、Constraint 方言和调用模式完全匹配的 `BoneProviderCapabilityVerificationIdentity` 时才启用；Bundled Catalog 当前没有此类真实 Smoke 身份，因此默认不会自动授权。普通云调用方无需接入 Llama Renderer、Tokenizer 或 Runtime 身份。

## Alpha.12 测试能力

需要验收 Host Persistence Adapter 时，在测试目标显式链接 `BoneAgentTesting`，调用 `BoneWorkflowPersistenceContractSuite`；无需修改生产目标依赖。此套件不随基础 Agent 自动运行，也不提供数据库。只使用 Agent 推理或本地只读查询的 App 不必为此新增任务持久化。示例及缺能力处理见 [Testing](Testing.md#host-持久化契约验收)。

## 从 alpha.22 迁移到 alpha.23

将 SwiftPM 精确版本更新为 `0.2.0-alpha.23` 并重新解析依赖。本版新增 Provider 与模型目录的统一入口：`BoneInferenceService` 聚合目录查询、模型列表与上游端点解析；`BoneInferenceProviderModelListLoader` 先请求上游模型列表，失败或不可请求时回退内置目录，并通过 `discoveryOutcome` 披露状态。`Entry.ident` 仍为字符串，既有目录查询、发现客户端和引擎调用不需要迁移；模型列表属于新增只读入口，不改变推理请求、凭据边界或持久化格式。完整用法见 [Provider 接入](ProviderIntegration.md#模型列表与上游地址)。本版未完成真实 Provider 或生产 Host 验收，不代表生产准入。

## 从 alpha.21 迁移到 alpha.22

将 SwiftPM 精确版本更新为 `0.2.0-alpha.22` 并重新解析依赖。本版扩展安全失败诊断，新增可选日志适配和默认关闭的受控失败响应采集；现有调用不自动开启任何日志或原始响应采集，无需数据库或 checkpoint 迁移，也不新增重试或改变稳定错误枚举。

需要排查 HTTP 拒绝时，Host 必须分别显式接入安全日志和私有采集回调；后者可能含服务端回显的用户内容或凭据，不得写入普通 Logger、错误映射或持久化。默认 SSE 非 2xx 采集有独立容量与固定时限，不产生 SSE 事件；注入的 `streamLoader` 没有原始错误正文，不提供该采集能力。完整代码与边界见 [Provider 接入](ProviderIntegration.md#可选安全日志与受控失败采集)。本版未完成真实 Provider 或生产 Host 验收，不代表生产准入。

## 从 alpha.20 迁移到 alpha.21

将 SwiftPM 精确版本更新为 `0.2.0-alpha.21` 并重新解析依赖。本版增加模型目录元数据、显式 reasoning 配置和 OpenAI/Anthropic 思考续接；默认行为保持兼容，未配置 reasoning profile 时仍不会自动开启思考参数。Host 必须根据实际渠道、模型和端点注入并验证 `BoneInferenceReasoningProfile`。本版未完成真实付费 Provider Smoke，不代表生产准入。

## 从 alpha.19 迁移到 alpha.20

将 SwiftPM 精确版本更新为 `0.2.0-alpha.20` 并重新解析依赖。此版修复 SDK 分块文件读写误用 iOS 13.4 Swift API 导致的 iOS 13.0 构建失败，不改变公开 API、最低系统版本、模型配置或安装数据格式，不需要数据库/模型数据迁移。不要修改 Xcode 下载缓存，也不需要通过提高 Host 的 deployment target 掩盖错误。

较低的 SDK 部署下限不会降低较新系统上的模型能力；真实后端 Binary 的最低系统、设备资源和 load/smoke 仍需单独核验，见 [最低系统版本与实际推理条件](LocalModels.md#最低系统版本与实际推理条件)。本次修复不补齐 Host 第三方库缺少的 Simulator 架构，也不等于完整 App 的模拟器链接已通过。已发布 alpha.19 tag 保持不变。

## 从 alpha.18 迁移到 alpha.19

从 alpha.18 升级到 alpha.19 前，请阅读 [上下文压缩](ContextCompaction.md)、[跨 Run 会话连续性](ConversationContinuity.md) 与 [Agent 实时事件流](AgentStreaming.md)。新能力均为显式 opt-in：上下文管理默认关闭，Conversation 需要 Host 自行加密/认证/CAS，实时流只接受真实 Provider event stream；不会自动迁移 Host 数据库、启用摘要、替换 Workflow checkpoint 或将 Llama 整段生成伪装成实时 delta。alpha.19 用于 Host 更新测试；请核对 tag 解引用的精确 SHA，再执行兼容与持久层验收，不将预发布等同于生产准入。

从 alpha.17 迁移到 alpha.18 的 Workflow Host 要求仍见 [Workflow Host 迁移与发布交接](WorkflowHostMigration.md)。

## 依赖方向

```text
UI ───────────────→ Business Service
Agent Adapter ────→ Business Service
Package ✕────────→ App Business Service
```

Package 不引用 Host 数据库、UI 框架、凭据存储或业务 Service。Provider Catalog JSON 与渠道图片是 Package 静态资源；用户密钥、自定义 Provider 和运行结果不进入 Resources。

正确的可退出性是：删除 Adapter 后，业务 Service 不受影响。如果删除 Adapter 会迫使数据库或业务领域重写，说明 Host 逻辑已经泄漏进 Package，必须先移回项目层。

## 接入门禁

1. 固定已审核版本，不跟随不稳定分支自动更新；
2. 在干净环境验证网络解析、构建和资源加载；
3. 保持公共 API baseline 和兼容策略；
4. 测试不得依赖任一 Host 的业务类型或本地目录；
5. 对新增第三方代码、资源、模型或 Binary 执行许可、来源和安全审计。

## 从 alpha.14 升级到 alpha.15

本版新增 API 均保留原初始化默认值，但需检查以下行为变化：

1. 默认 Debug 不再记录请求正文。若确需敏感载荷，应额外启用 `includesSensitivePayloads`，
   并限制日志留存与访问权限。安全响应诊断不需要开启 Debug。
2. 日志事件 `inference.response.received` 更名为 `inference.result.validated`。
   原名称并不能证明 HTTP 到达；新诊断 sink 的 httpResponseReceived 才表示完整响应返回。
3. 默认 Agent 仍为非流式。显式 bufferedStreaming 必须具有 totalTimeout、Host deadline
   或 Run 墙钟预算之一，且 Engine 实现 BoneInferenceBufferedStreaming。
4. Host deadline 必须基于 ProcessInfo.processInfo.systemUptime；不要传 Date/Unix 时间。
5. serverReasoning 与 reasoningDisclosure 独立；默认不发送扩展字段，不能把 hidden 解释为关闭 Thinking。

接入示例见 [ProviderIntegration](ProviderIntegration.md)，离线场景验证见 [Testing](Testing.md)。
SDK 不迁移 Host 的数据库、旧日志收集规则或既有任务预算，不自动修改用户模型参数。

## 从 alpha.15 升级到 alpha.16

本版为定向修复，无新增启用选项。拒绝 OpenAI/Anthropic 语义终态后的 Tool 参数追加，
保留 Agent 用户取消语义，并修正非法诊断字段与 max_output_tokens 摘要。
正常协议序列保持兼容；非法序列会失败且不执行 Tool，不能通过放宽校验恢复旧行为。
Host 应复跑既有非法序列和真实取消用例，再评估启用角色提取流式；不代表 Agnes 超时原因已解决。
