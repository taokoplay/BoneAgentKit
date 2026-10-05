# 跨本地与在线模型的上下文压缩

## 入口与默认行为

`BoneAgentConfiguration.contextManagement` 是可选配置，默认 `nil`，因此现有 Host 的请求不会自动改变。启用后，`BoneAgent` 在每次业务推理前执行相同的预算解析、工具结果限长、完整 Turn 裁剪与可选摘要。直接调用 `engine.infer` 不自动改写历史；`BoneContextCompactor` 是供 Host 独立使用的消息级规划器，不包含完整请求的 Tool Schema 开销。

统一预算 `BoneContextWindowBudget` 区分：

- `model`：来自 `BoneModelContextLimits` 的已验证模型/网关容量；
- `runtime`：来自本地实际 Runtime Plan 的有效容量；
- `host`：Host 主动设置的业务上限，不等同于官方模型事实。

未知容量保持未知，不按模型名称猜测。Host 显式 provider 返回 `nil` 时不管理该请求；已产生摘要的同一 Run 不能中途撤销预算并丢失摘要。Host 的自定义预算会与 Engine 已知上限取更严格者。

## 在线模型

OpenAI-compatible、Anthropic、Gemini 构造器新增可选 `modelContextLimits`，以精确模型 ID 为 key。该字典绑定本 Engine 实例的站点；不能把一个站点的限制复制给所有兼容网关。

```swift
let engine = BoneOpenAIInferenceEngine(
    configuration: providerConfiguration,
    transport: transport,
    modelContextLimits: [modelID: verifiedModelLimits]
)
let context = try BoneContextManagementConfiguration()
let configuration = try BoneAgentConfiguration(
    maximumSteps: 20,
    contextManagement: context
)
```

没有可选 `BoneInferenceContextBudgetProviding` 能力的自定义 Engine，可在配置中注入 `budgetProvider`。默认在线估算包含消息、工具定义、响应格式/输出约束与不透明续接数据的保守开销；估算不是厂商真实 Tokenizer，仍可能低估，不能保证远端永不拒绝。当前不因远端 400/网络错误自动重试。

## 本地 Llama

`BoneLlamaInferenceEngine` 从 `BoneLocalRuntimePlan` 暴露 runtime budget；Kit Core 不反向依赖 Llama。它还实现 `BoneInferenceContextTokenCounting`，经实际 Renderer 和 Runtime Tokenizer 计算完整 Prompt，包括模板和 Tool Envelope。

```swift
let configuration = try BoneAgentConfiguration(
    maximumSteps: 20,
    contextManagement: .init()
)
// inferenceEngine 传入已装配的 BoneLlamaInferenceEngine。
```

Token 预检可能加载模型，但不会生成。它遵守已有 busy、取消、unload/drain 语义。正式推理仍重新渲染/分词并由 `BoneLlamaPromptExecutionPlanner` 守住原生 decode 边界；目前未缓存预检结果，多次候选测量有额外 CPU 成本。它不是 KV Cache 压缩，也不是把 Prompt 按字符切成独立请求。

默认管理策略为小窗口按比例选择输出与余量：未配置输出偏好时最多取窗口四分之一且不超过 4096；默认协议预留 128 Token、安全余量为 `max(16, contextWindow / 50)`。最终输出会受调用方值、偏好和模型上限收紧，并真正写入发送请求。旧 `BoneContextWindowPlanner` 的 512/1024 默认值保持不变。

## 策略与工具边界

默认在可用输入预算的 85% 触发，裁剪目标为 65%，保留至少最新一个用户 Turn。一个 Turn 包含用户请求以及随后的全部 Assistant/Tool 交换。

- 前置 system 消息保留原文、原顺序；中途 system 消息不搬到开头，启用有效预算后在预检时明确拒绝。
- 默认只删除完整旧 Turn，不拆开 Tool Call/Result。重复 ID、缺结果、孤立结果、错误 toolID/ordinal 等拒绝处理。
- 默认当前用户消息和最近保留 Turn 不裁剪。若仍装不下，返回 `contextManagementFailed`，不发送半成品请求。
- Tool Result 默认 `.retain`。Host 可按精确 Tool ID 指定 `.clamp(maximumBytes:)`；JSON 被限长后变为明确标记的 text，保留 callID/toolID/ordinal/isError。UTF-8/组合字符不会被字节切坏。
- `clamp` 是有损的；Host 须判断该工具结果是否允许丢失细节。不会自动重跑工具或删除副作用 Receipt。小于完整 `[context-compacted]` 标记长度的配置明确报错，不静默违反声明的上限。

```swift
let context = try BoneContextManagementConfiguration(
    toolResultPolicy: { toolID in
        toolID == "project.readLargeLog" ? .clamp(maximumBytes: 8_192) : .retain
    }
)
```

### 单个长任务的可选整理

默认仍保护整个当前用户 Turn。对需要多次工具往返的长任务，Host 可显式设置 `minimumRecentToolExchangeCount`（必须大于 0）：

```swift
let context = try BoneContextManagementConfiguration(
    summarizer: summarizer,
    minimumRecentToolExchangeCount: 2,
    failureSink: { diagnostic in
        // 保存固定错误分类，或提示用户缩小输入；不记录原始错误正文。
        print(diagnostic.rawValue)
    }
)
```

开启后，在旧用户 Turn 裁剪仍未达到目标时，可进一步移除**当前 Turn 中已完成的旧 Assistant Tool Call / Tool Result 对**。当前用户指令原文、前置 system、最近指定数量的交换、未配对调用均不允许拆分或丢弃；普通文本消息不按此策略删除。历史先校验完整配对，再构造候选、重绑定 Provider continuation 并计算预算，成功后才提交。移除的交换会交给可选摘要器；没有摘要器或允许的摘要质量回退仍可能直接裁剪，因此这是显式有损策略，不是事实保真保证。

`receipt.removedToolExchangeCount` 单独计数，不将删除两个消息虚称为删除一个用户 Turn。新字段解码旧 receipt 时为 0。一个工具结果本身过大、或保留部分仍超限时依旧明确失败，不为腾空间删除最新结果或当前用户指令。

`failureSink` 提供固定白名单分类，例如 `inputExceedsBudget`、`invalidHistory`、`continuationUnsupported`、`summaryUnavailable`。公开 Run 错误保持 `contextManagementFailed` 兼容；取消和 RunBudget 仍沿原错误通道，不记录正文或底层错误字符串。

Gemini 压缩后通过 Provider adapter 重绑定保留的、唯一且未修改的 Assistant Turn 签名；删除历史 Turn 时删除对应签名。未知 continuation 格式/未实现重绑定的 Engine 不会静默清空 continuation 继续。

## 可选语义摘要

摘要不会自行选择在线模型。Host 必须显式绑定 Engine、模型 ID 和独立容量；可绑定本地模型、同一 Engine 或另一在线模型。跨站点或本地转云意味着新的数据外传，Host 应先完成授权。

```swift
let summarizer = try BoneInferenceEngineContextSummarizer(
    engine: summaryEngine,
    modelID: summaryModelID,
    budget: summaryBudget,
    costEstimator: summaryCostEstimator
)
let context = try BoneContextManagementConfiguration(
    summarizer: summarizer,
    maximumSummaryOutputTokens: 512,
    maximumSummaryCallsPerRun: 4
)
```

确定性阶段产生待移除旧 Turn 后，摘要模型读取遵守 Tool Result 限长策略的历史投影与上一份摘要；模型结果通过格式、终态、长度及目标请求预算验证后，才提交新历史。文本摘要要求目标、事实、约束、决定、执行结果、待办和不确定项，但不是形式化事实保真证明。

摘要请求没有业务工具、continuation、reasoning disclosure 或强制结构化输出要求。Llama 即使配置过 Tool Envelope，也支持无工具的普通文本摘要请求。摘要以明确标记的**不可信历史数据消息**插入，不能提升为 system 权限，也不能替代当前用户请求。它仍可能携带错误或注入内容，Host 不得据摘要执行授权判断。

第一期每次压缩最多一次摘要请求，不分块递归摘要；摘要输入必须装入摘要模型自己的容量。若装不下、达到摘要次数上限、返回空/过大/截断/非法形态，按 `fallbackToTrimming` 回退确定性裁剪或停止。网络失败、未知结果、取消、预算耗尽不会吞掉后继续或盲目重试。

摘要与业务推理共用 Run 的推理次数、输入/输出字节、估算费用与 wall-clock 预算；摘要不消耗业务 `maximumSteps`/`maximumTurns`。启用 RunBudget 时摘要需独立 `costEstimator`，不能把另一个模型套用主模型的费率。未启用 RunBudget 时仍受摘要次数上限与模型输出预算限制。所有截止均为协作式边界检查，不强制终止不配合取消的原生调用。

## 可观测性与恢复

- `receiptSink` 只交付成功提交的 Run-local 压缩计数/revision/请求 Token 减少量（`estimatedRequestTokenReduction`）；它不是磁盘持久化成功证明。
- `summaryAttemptSink` 交付每次已开始摘要调用的完成/拒绝/失败/取消、是否收到响应及可得 Usage。没有 Usage 时保持未知。
- 业务 `RunModelSnapshot` 不混入另一摘要模型的 Usage；它记录原 Run 配置，不能据此复现每次动态收紧的输出上限。需要完整费用统计的 Host 必须同时收集摘要尝试事件。
- 开启管理时，Agent 自带完整请求 Debug 日志也会省略请求正文；外部自定义 Engine/Transport/Host 日志不在此保护范围。
- 原始历史、摘要和 continuation 默认只驻留本次 Run 内存，不进入标准 Workflow checkpoint；摘要不增加 Workflow 的业务响应/Tool result 计数。

`BoneContextHistoryPersistence` 仅定义 Host 私有上下文存储的**引用 CAS 接入契约**（opaque ID、revision、lease generation）。没有默认磁盘实现，Agent 不隐式调用它；Host 负责内容加密、事务、租约、保留/清理及结果未知时重读。该引用不能单独恢复会话，不能被当成内容证据。第一期不提供跨 Run 自动恢复完整压缩会话；Host 仍需要自己的完整历史/执行状态重建流程，不能在未知 Tool 副作用后重放工具。

## 验证范围与限制

离线回归覆盖三类云协议映射、Llama Runtime Fixture、共享本地摘要、预算计费、失败/取消、UTF-8、Tool 配对与 Gemini 签名重绑定。测试不使用真实凭据，不证明特定在线模型或实际 GGUF 摘要质量。

默认不拆分当前用户 Turn；显式开启当前 Turn 旧工具交换整理后，只处理完整且已完成的旧交换。单条过大用户输入或必须保留的最近交换仍无法缓解时稳定失败。公开消息结构自身的字节/数量限制、Llama 的基本请求校验仍适用。高级分块摘要、跨 Run 自动恢复、Provider-native compact API、长期记忆和 KV Cache 压缩不属于本期交付。
