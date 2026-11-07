# Token 用量与会话统计

## 统一入口

`BoneAgentConfiguration.tokenSink` 返回 `BoneAgentTokenSnapshot`，覆盖普通、buffered streaming、实时 `runEvents` 和 Conversation 调用。每次通知中，`statusSink` 的 `status.tokens` 与 `tokenSink` 收到同一份快照。默认合并 100 ms 内的高频统计变化，阶段切换、预算就绪/拒绝、请求完成和 Run 终态立即刷新。`await agent.currentTokens` 可主动读取尚未通知的最新计数和活动时长；`currentStatus.tokens` 保留最近一次生成状态快照时的值。

```swift
import BoneAgentKit

func makeMeteredAgent(
    engine: any BoneInferenceEngine,
    render: @escaping @MainActor @Sendable (BoneAgentTokenSnapshot) -> Void
) throws -> BoneAgent {
    try BoneAgentBuilder(inferenceEngine: engine)
        .withConfiguration(.init(
            maximumSteps: 40,
            contextManagement: .init(),
            tokenSink: .init { snapshot in await render(snapshot) }
        ))
        .build()
}
```

没有配置 Token 回调时仍可读取当前快照。两种回调在同一 Run 内有序 await；不要在回调里等待本轮执行结束。计数及模型/工具耗时变化按事件刷新，SDK 不创建每秒定时器。需要正在运行的计时动画时，Host 可按 UI 刷新频率查询 `currentTokens` 或 `conversation.statistics`；查询不会增长事件序号，活动时长会按当前单调时钟刷新。

快照包含 Run ID、递增序号、上下文预算、摘要上下文、模型请求明细、工具计时和可选终态。无提示词、回复、思考原文、工具参数/结果、图片引用或凭据。它不自动序列化，也不进入既有 Workflow checkpoint 或 Conversation 私有存储。

## 当前上下文与累计消耗

`context` 描述**下一次/最近一次规划的模型请求输入**，并不是整个会话累计消耗。预算来自真实规划器测量，不会再次读取图片或调用另一个 Tokenizer。

| 字段 | 含义 |
| --- | --- |
| `inputTokens` | 输入测量，含文字、每次图片出现、Tool Schema、协议包装、约束与 continuation |
| `source` | `estimate` 为估算；`tokenizer` 为 Engine 提供的实际渲染计数；`unavailable` 为未知 |
| `inputTokensBeforeCompaction` | 本次整理前的输入量，供对比 |
| `availableInputTokens` | 已扣除输出、协议及安全预留后的可用输入容量，并受模型独立输入上限限制 |
| `reservedOutputTokens` | 规划时真正采用的输出额度 |
| `protocolReserveTokens / safetyMarginTokens` | 本次规划实际预留 |
| `compactionTriggerTokens / compactionTargetTokens` | 对应默认 85% / 65% 或 Host 自定义比例 |
| `utilization` | `inputTokens / availableInputTokens`；不是占整个窗口的比例，拒绝时可大于 1 |
| `remainingInputTokens / tokensUntilCompaction` | 距硬输入容量或压缩触发值的余额，下限为 0 |
| `imageCount / revision` | 本次投影图片出现次数和压缩版本 |

阶段为 `beforeCompaction → compactionCandidate → ready`，超限或计数不可用可为 `rejected`。候选只是测量，不表示历史已提交。压缩后会发布新的实际输入量；当前输入无法压缩进容量时，拒绝快照先于模型调用。下一步骤预算检查会清空上一轮预算投影，避免把旧值误认为本轮已经完成测量。

未启用上下文管理或 Host 显式禁用时，`stage = unmanaged`。SDK 尽量用已有纯估算规则提供 `inputTokens`；未知视觉规则、溢出等保留 nil，不能按 0 使用。此时不会为展示而加载本地模型/Tokenizer，也不假定输出额度、安全余量或压缩阈值，因此可用容量与比例为 nil。需要准确的压缩 UI，应启用 `contextManagement` 并提供模型容量；未知容量仍保持未知。图片预检和请求发送的原有限额不受观察器替代。

## Provider 用量：同一请求替换，跨请求累加

`requests` 是有界的最近请求明细，每条包含唯一 ID、模型 ID、主推理/摘要用途、步骤、状态和用量。总统计覆盖全部调用，不得通过明细数组长度或求和替代总统计：

- `provisionalUsage`：当前请求最近一次流式累计快照，新的报告替换旧值，**不逐 chunk 相加**。请求中断后仍可保留，不能当作完整结算。
- `finalUsage`：Engine 已交付完整响应中的用量。只确认一次，随后同 ID 的迟到事件忽略。
- `state`：`inFlight`、`responseReceived`、`failed` 或 `cancelled`。收到响应之后的输出校验、预算或 checkpoint 失败不会抹去已经发生的响应和用量。

`total`、`business`、`summaries` 和 `totals(forModelID:)` 只累计已收到完整响应的最终报告，不混入预算估算或中断请求的临时用量。摘要结果被拒绝/回退时，已经发生的摘要调用仍计入 summaries。业务模型快照原有 `totalUsage` 仍保留旧口径，不能再与新接口的 total 相加。

`knownUsage` 是已知部分；`requestCount`、`reportedResponseCount`、`unreportedResponseCount`、`unresolvedRequestCount` 和 `isComplete` 给出覆盖度。没有报告的请求不会被当作零；可选字段缺失保持未知。整数溢出饱和到 Int.max 并设置 `overflowed`，此时不声称统计完整。临时 usage 即使看起来完整，也必须等待 final 才进入累计。

`BoneInferenceUsage` 的字段继续保持 Provider 语义：输入、输出、缓存读取、缓存写入、推理 Token。不同厂商的缓存/推理字段可能是子集或独立报告，SDK **不把这些字段全部相加**成一个伪总数，也不替代供应商账单。跨不同模型的聚合仅为已报告计数之和，费用计算应按模型和费率分别处理。

OpenAI、Anthropic、Gemini 实时流均报告 usage。Anthropic 合并 `message_start` 与 `message_delta` 的累计字段；缺少必要输入/输出数时暂不造值。约束输出即使不向用户展示正文 delta，统计通道仍可收到用量。各厂商通常只在开始/结尾或有限时点提供 usage，因此不是逐 Token 的精确滚动计数。非流式与 buffered 在完整响应后更新最终用量。

## 会话统计与截图字段

```swift
func readSessionStatistics(_ conversation: BoneAgentConversation) async -> BoneAgentStatistics {
    await conversation.statistics
}
```

Conversation 使用增量累计，结束的轮次折叠为固定大小的数值汇总，不再保存它们的完整统计快照；运行时最多保留当前轮快照。普通调用也可将**有界数量**的快照交给 `BoneAgentStatistics(snapshots:)` 做批量聚合，它按 Run ID 取最大序号并包含被淘汰明细的完整累计值。Host 不应把每帧快照永久追加到内存数组；独立 `agent.run` 不会自动累加到某个 Conversation。

| 界面字段 | API | 统计口径 |
| --- | --- | --- |
| 轮数 | `roundCount` | 本观察范围内受理的用户 Run，包括失败/取消；`successfulRoundCount` 单列成功轮数 |
| 步数 | `stepCount` | 主模型调用尝试数，摘要调用另列 `summaryCallCount`；不是工具数或文本片段数 |
| 模型用时 | `modelDurationSeconds` | 从 SDK 登记主模型尝试到记录响应、失败或取消的区间之和；活动区间计至快照采样时刻 |
| 摘要用时 | `summaryDurationSeconds` | 从 SDK 登记摘要尝试到记录响应、失败或取消的区间之和，独立于主模型 |
| 工具调用用时 | `toolDurationSeconds` | 各工具执行闭包区间之和，并行重叠重复计入 |
| 工具实际等待 | `toolWallDurationSeconds` | 每轮工具区间取并集，再跨轮累加；不重复计算同轮并行重叠 |
| 工具调用数 | `toolCallCount` | 已进入工具执行边界的尝试，权限/准备阶段不计入 |
| 首 Token 平均（TTFT） | `averageTimeToFirstTokenSeconds` | 有效主模型样本的算术平均，样本数为 `timeToFirstTokenSampleCount` |
| 输出速度（TPS） | `outputTokensPerSecond` | 有效主模型样本的输出 Token 总数 / 输出区间总秒数，样本数为 `throughputSampleCount` |

模型与摘要计时均包含调用前观察回调的等待，以及 Engine 内部的请求准备、网络等待和校验。若在调用前回调中取消，Engine 正文尚未开始也可能已有非零尝试用时。收到完整响应后先记录请求结束，再交付完成通知；后续 Agent 预算检查或 Tool 执行不计入该请求用时。这些值不能解释为纯 Engine 执行或服务端计算时长。

TTFT 从 Provider 即将发送请求，到首个非空生成片段。片段可为正文、可观察的思考文本或工具参数；空事件、心跳、header、签名及纯 block-start 不计入。隐藏思考正文不影响收到实际片段时的计时，但不可观察的远端思考没有人为估算。

TPS 的输出区间从首个有效片段到流结束，使用 Provider 最终 `outputTokens`；这是基于网络分块的客户端速率，不是服务端逐 Token 性能计量。首个分块本身可能含多个 Token，网络、排队和观察回调都会影响测量。仅选完整响应、有输出 Token、可靠实时传输且区间大于 0 的请求；不使用字符数估算，不平均各轮 TPS。零时长、非法时钟、没有流式样本或没有最终用量时返回 nil，不返回无穷大或伪造 0。

`BoneInferenceHTTPTransport.providesLiveEventTiming` 默认 false。默认 URLSession 实时桥接为 true；注入的 buffered loader 或兼容 `eventStream` 回放为 false。自定义真实逐事件 Transport 须显式声明 true；不能把一次性回放当作 TTFT。自定义 Engine 可用 `BoneInferenceTelemetryReporting` 上报累计 usage 及实际时点，必须遵守同一口径。

同一 Conversation 实例内自动累计各轮并即时更新。恢复私有会话不会恢复历史计时/用量，只统计此实例观察到的 Run。完整性标记按创建实例时的会话 revision 决定：恢复 revision 大于 0 的会话时，`isHistoryComplete = false`；恢复 revision 为 0、尚无已完成轮次的会话时仍为 `true`。不能从对话文本长度倒推以前的消耗。需跨启动保留统计时，Host 应显式保存安全业务统计，不把观察快照当成恢复执行许可。

## 长会话与多会话的性能策略

默认 `observationPolicy` 保留最近 64 条**已完成请求**、128 条**已结束工具**明细，以及每个 Run 最先遇到的 16 个模型的分项累计。活动调用额外保留到结束；SDK 自身模型调用串行，工具并发受已有调度上限约束。`total/business/summaries/statistics` 始终覆盖全部调用。

- `omittedRequestCount` / `omittedToolTimingCount` 明确指出已淘汰明细数，淘汰不影响 Token、耗时、TTFT 均值或加权 TPS。
- 模型分项达到上限后，不再保存新模型键，`omittedModelRequestCount` 标记其请求数。先用 `hasModelBreakdown(for:)` 检查；缺失模型分项的空 totals 不代表该模型实际消耗为零。
- 请求结束后移除其可变时钟、临时索引；完整统计通过固定大小的累计量维护。工具重叠时长随开始/结束增量累计，不对全部旧区间重复排序。
- 每帧快照成本取决于配置的明细上限和活动调用数，不再随已完成的历史调用数增长；单个已结束会话的统计查询为固定工作量。
- 100 ms 合并只减少观察通知，不减少计数。无后台刷新 Task 或 timer，闲置会话不会为统计持续唤醒；后续满足间隔的统计事件、阶段切换或终态会交付最新累计值。主动读取 `currentTokens` 或 `conversation.statistics` 可取得最新计数及活动时长。

```swift
let observationPolicy = try BoneAgentObservationPolicy(
    maximumRequestDetails: 32,
    maximumToolDetails: 64,
    maximumModelBreakdowns: 8,
    minimumTokenUpdateInterval: 0.2
)
let configuration = try BoneAgentConfiguration(
    maximumSteps: 40,
    observationPolicy: observationPolicy
)
```

请求明细上限支持 1…1024，工具明细 0…1024，模型分项 0…128，刷新间隔 0…60 秒。间隔 0 是显式逐次通知选择；不建议大量会话的 UI 使用。此策略不改变模型输入、工具结果、上下文压缩阈值或计费判断。

**统计层有界不等于整个 App 内存固定。** 正文历史、Provider 在途响应、图片存储/解码和本地模型由各自边界管理。Host 应为活跃会话数、图片缓存和 UI 历史设总预算；闲置会话可通过已有私有状态导出后释放，按需恢复。旧 `modelSnapshotSink.usageByResponse` 仍保持完整单 Run 明细契约，使用 `maximumSteps`/RunBudget 限制单次任务长度。调用方自己保留所有快照，仍会造成内存增长。

本机 Debug 固定 2000 次请求并逐次查询统计的微基准，优化前约 5.19 s、保留 2000 条请求，优化后约 0.017 s、保留 64 条；同一工作量累计输入仍为 200000 Token。此结果仅衡量统计路径，不代表真实模型运行加速。压力测试还覆盖 128 份会话统计各 1000 轮（已结束快照保留数为 0），以及 64 个真实 Agent/Conversation 对象各 100 轮并验证全部释放；后者的离线测试进程峰值约 37.5 MiB，包含测试框架，不能直接当作真机或业务 App 的内存上限。

## 验证范围

`AgentTokenStatisticsTests` 使用可控时钟和实际 Agent 流程验证累计去重、未知值、摘要隔离、图片压缩阈值、并行耗时并集、三轮会话、TTFT/TPS、溢出、取消与隐私。`ProviderTelemetryTests` 使用合成 HTTP/SSE 验证三家协议、五种调用入口、时点、隐藏/约束输出和缓冲回放门禁。没有真实付费请求，测试不代表线上账单或模型性能基准。
