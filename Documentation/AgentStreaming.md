# Agent 级实时事件流

## 当前状态（2026-11-25）

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| `runEvents` 基础实时事件 | 已实现 | 只接受真实 Provider event stream，只有 Agent `completed` 才是正式成功终态。 |
| `runObservedEvents` | 已实现、已测试、Demo 已接入 | 提供 `runID`、本流 `sequence`、有界队列、背压、取消和完成结果独立收口。 |
| OpenAI、Anthropic、Gemini 有界流 | 已实现、已测试 | 使用统一 Flow Control 协议和 URLSession 逐帧 Transport。 |
| 本地 Llama 逐事件流 | 未实现 | 当前 runtime 只有整段生成接口，没有可验证的 token/delta seam。 |
| 真实 Provider 网络 Smoke | 生产待验收 | 当前测试使用离线 Engine、注入 Transport 和 URLProtocol，不代表账号、网络、服务端吞吐或线上取消行为。 |
| RSS、长时间慢消费者和最低系统版本基线 | 生产待验收 | 逻辑队列预算已经有边界，尚未完成真实设备和长时性能基线。 |

本页后续的 API 说明描述已经存在的 SDK 契约。整体成熟度、Demo 接入范围和未完成工作见 [SDK 状态与路线图](SDKStatusAndRoadmap.md)。

`BoneAgent.runEvents` 是显式 opt-in 的实时入口。它只在当前 Engine 实现真实的 `BoneInferenceEventStreaming` 时工作；只有 buffered streaming 或整段返回的 Engine 会在调用前 fail closed，不会把完整响应伪装成文本 delta。

需要显示“检查预算、压缩中、摘要中、思考中、执行工具”等阶段时，配置 `BoneAgentConfiguration.statusSink`。它覆盖普通、buffered、实时流及会话调用，不依赖是否展示思考正文；`runEvents` 保持原有正文/工具事件。详见 [Agent 统一运行状态](AgentStatus.md)。

## 使用方式

```swift
let stream = try await agent.runEvents(
    request: .init(
        modelID: "provider-model-id",
        messages: [.init(role: .user, content: "请开始")]
    ),
    options: .init(totalTimeout: 90),
    boundary: .untilModelFinish
)

for try await event in stream {
    switch event {
    case .runStarted:
        break
    case let .textDelta(_, text):
        renderDraft(text)
    case let .reasoningDelta(_, text):
        renderReasoningIfAllowed(text)
    case let .modelToolCallStarted(_, callID, toolID):
        showToolDecision(callID: callID, toolID: toolID)
    case let .toolExecutionStarted(_, callID, toolID):
        showToolExecution(callID: callID, toolID: toolID)
    case let .toolResultReady(_, callID, _, isError):
        showToolResult(callID: callID, isError: isError)
    case let .completed(result):
        showFinalResult(result)
    default:
        break
    }
}
```

`runEvents` 仍受 Agent actor 的串行运行所有权约束。流返回后，当前 Run 仍在执行；在 `.completed` 或流抛出终态错误前，另一个 `run` / `runEvents` 会返回 `runAlreadyInProgress`。

## 事件语义

- `runStarted`：Agent 已完成能力门禁并开始 Run。它不是持久状态事实。
- `textDelta`：Provider 已交付的公开文本片段，只是未完成展示草稿。它不等于最终输出，不能据此更新 Conversation、Workflow checkpoint 或授权事实。
- `reasoningStarted` / `reasoningDelta` / `reasoningCompleted`：只有请求允许的 reasoning disclosure 才会收到；hidden 模式不会发送。reasoning 不是业务事实或授权依据。
- `modelToolCallStarted` / `modelToolCallFinished`：模型正在形成 Tool Call 的元数据，不代表 Tool 已执行。原始 Tool arguments 不进入 Agent 流。
- `toolExecutionStarted` / `toolResultReady`：Agent 已进入实际 Tool pipeline 或已接受 Tool 结果。结果正文、参数和 Effect payload 不进入事件。
- `usage`：Provider 的临时 usage 观测。正式预算和模型快照仍以完整响应为准，不能将它再次累计为费用事实。
- `completed`：唯一的成功终态。它包含经过 Provider 验证、Agent Tool Loop 和成功线性化点处理后的 `BoneAgentBoundaryResult`。

Provider 的 `.completed` 不直接暴露给调用方。Agent 必须先收到且验证完整响应，才会执行 Tool 或产生最终 Agent `completed`。没有完整响应的正常 EOF、重复 completed、completed 后继续事件、非法工具事件都会 fail closed。

## 失败、取消与取消边界

流抛出错误时，之前收到的 delta 只能作为未完成草稿。不要把已显示的正文拼接后当作正式 Assistant 消息。取消会向下传递到 Provider event stream。对于 Agent 直接 await 的工具或推理调用，仍需等待该调用返回或抛错后才能退出执行路径；若调用内部另建生产任务，清理责任仍由该实现承担。

事件流的独立生产任务有不同的退出边界：内置 Provider 在流终止时请求取消生产 Task，Agent 不等待该 Task 的清理完成。因此，Agent 的取消终态或运行所有权释放不能证明所有 Provider/Transport 生产任务已退出，也不能证明远端请求已停止。Host 应按对应执行接口的完成、取消或对账契约判断资源与副作用状态。

裸 `AsyncThrowingStream` 的消费方应取消持有消费任务来停止生产。`break` 不应被理解为强制终止所有底层工作；对于需要显式停止按钮的产品，应由 Host 持有并管理自己的 Task/Run handle。

既有安全 `BoneAgentEvent` 保持不变：它仍只包含 `runStarted`、Tool 生命周期和安全 `runFinished`，不会混入正文、reasoning、Tool 参数或 continuation。实时流也不进入日志、模型快照或普通 Workflow checkpoint。

## Provider 和本地模型边界

OpenAI、Anthropic、Gemini 当前已有 provider-neutral 增量事件。约束输出或结构化结果在验证完成前可能没有 `textDelta`，这是预期行为；Agent 不会从未经验证的 delta 自行重建 JSON 或 Tool Call。

本地 Llama 当前只有整段 `generate` 返回和模型状态通知，没有安全的 token/delta runtime seam。因此 `BoneLlamaInferenceEngine` 不承诺 `runEvents`。后续若增加本地实时能力，应新增可选 runtime streaming 协议，并处理 Unicode 分片、stop string 缓冲、reasoning marker、Tool envelope、约束输出、取消和单一终态；不能直接把原始 runtime token 当作公开正文。

实时流不改变普通 `run`、buffered streaming、Workflow 或 `BoneAgentConversation` 的现有语义。跨 Run 会话仍只在成功的完整用户 Turn 后更新，实时 delta 不会提前写入私有会话状态。

## 可选的有界观察流

`BoneAgent.runObservedEvents` 在保留旧 `runEvents` 的基础上，提供单消费者、带运行关联信息的有界入口。核心 SDK 只交付事件、身份和容量统计，页面、渲染、历史列表及用户交互仍由接入方负责；测试 Demo 只验证这些契约。

```swift
let limits = try BoneEventBufferLimits(
    maximumEventCount: 64,
    maximumQueuedPayloadBytes: 2 * 1_024 * 1_024,
    maximumEventPayloadBytes: 512 * 1_024
)
let stream = try await agent.runObservedEvents(
    request: .init(modelID: "provider-model-id", messages: [
        .init(role: .user, content: "请开始")
    ]),
    options: .init(totalTimeout: 90),
    buffering: limits
)
for try await envelope in stream {
    // 将 event 交给宿主；可用 runID 与 statusSink/tokenSink 关联。
    // sequence 只在这个事件通道内比较，不与状态或 Token 序号比较。
    consume(envelope.runID, envelope.sequence, envelope.event)
}
let occupancy = stream.bufferSnapshot
```

### 能力与兼容

- 旧入口、事件 enum、普通 Run、Conversation、Workflow 和默认缓冲行为保持可用。
- 新入口要求 Engine 显式采用 `BoneInferenceFlowControlledEventStreaming`，并在 `validateEventFlowControl()` 中完成无网络的本地能力检查。旧流转发器不能以外层加限额的方式宣称端到端流控。
- 内置 OpenAI、Anthropic、Gemini Engine 已实现新协议；它们还要求实际 Transport 采用 `BoneInferenceFlowControlledHTTPTransport` 且提供真实到达时序。默认 `BoneInferenceURLSessionTransport` 满足条件；只提供整段 `StreamLoader` 的注入实例不满足。
- 不支持时在接受新 Run 之前抛出 `BoneEventStreamError.flowControlUnavailable`，不静默退回旧无界流，也不替换已有运行状态。本地 Llama 没有逐事件 runtime seam，仍不承诺此入口。

### 身份与顺序

`BoneAgentObservedEvent` 包含 `runID`、从 1 开始的 `sequence` 和原有 `BoneAgentStreamEvent`。`step` 仅为原事件的便捷读取。Run ID 与这次执行的 `BoneAgentStatus`、`BoneAgentTokenSnapshot` 一致；不同运行独立生成，不能与 Workflow 的持久 Run ID 混用。

序号表示本流交付顺序，迭代器副本共享计数，不因复制而重新编号。不同观察通道各自有序，不承诺跨通道的全局总序。信封含有原实时事件的私有正文，故不自动 Codable、不写普通日志，不作为授权、恢复或 checkpoint 依据。

### 容量、背压与完成结果

默认 limits 为 256 个排队事件、8 MiB 排队逻辑载荷和 8 MiB 单事件载荷。自定义 limits 必须均大于零，单事件上限不得大于排队字节上限。

Provider 转换和 Agent 消费使用可取消的 `send` 等待容量。原生 URLSession 回调逐帧使用不能等待的 `offer`：队列满或单事件超限时明确失败并取消网络请求，不保留一个缺失了 token 的“成功流”。Framer 的请求级 `maximumBytes` 继续约束总网络响应；内置 Provider 在新路径还复验累计事件载荷，不能通过不断消费清空队列绕开总量限制。

每层队列各自使用 limits；`stream.bufferSnapshot` 只描述 Agent 正文队列，不是三层合计。逻辑载荷按字符串 UTF-8、Data、正式响应的临时 JSON 表示和固定信封开销计量；编码结果仅用于计数，不保存、不输出。预算不等于 RSS，也不包括解析器、聚合器、调用方保留的历史、正在处理的值或尚未入队的发送值；自定义生产者仍需约束并发。

Agent 另有一个完成结果槽位，不占正文队列事件数，其大小继续受 `maximumEventPayloadBytes` 限制。正常结束先读完排队正文，再交付唯一的 `completed`，避免因正文排队满而阻止已完成执行收口。Agent 层总留存上限因此是正文队列预算加一个受限结果。执行收口后可以释放运行所有权，宿主可能仍在消费旧流的缓冲事件；用信封 ID 区分后续运行。

### 失败与取消

- `eventTooLarge`、`bufferOverflow`、`invalidPayloadSize` 均为显式失败；失败前已接受的事件可继续按序读完，但不会再生成成功终态。重复消费同一个流报 `multipleConsumers`。
- 容量错误可能早于生产任务的异常收口送达，此时 `currentStatus` 仍可能是活动阶段。若需要确认运行终态或开始下一次执行，等待 `statusSink` 终态及已有所有权/恢复契约，不把“流已抛错”当作清理完成。
- 取消消费任务、提前退出迭代或释放尚未消费的有界流，会请求取消生产者并唤醒挂起的 send/next。它不证明远端请求或外部副作用已停止，也不覆盖既有 Effect 对账契约。
- 请求级 `totalTimeout` / `deadlineUptime` 在 Provider 生产和 Agent 推理流消费的背压等待中继续生效，每次推理仍受现有 Run 剩余预算限制。工具阶段继续采用既有协作式预算和取消边界，不宣称可以强制中断任意 Host 工具或回调。
- 正式执行成功之后，完成结果若因单事件上限而无法投递，流会报 `eventTooLarge`；已经确认的成功状态、模型快照和工具 Effect 不回滚。投递错误不是重新执行许可，宿主须按已有持久事实和对账流程决定后续操作。

### 自定义流控实现

`BoneBoundedEventStream.makeStream(limits:payloadSize:)` 返回 stream 与 producer。异步生产按序 `try await producer.send(value)`；不能挂起的回调使用 `offer` 并检查结果。用 `producer.onTermination` 连接底层 Task/请求取消，再用 `finish()` 或 `finish(throwing:)` 收口。终止回调只调用一次，并处理终止先于 handler 安装的竞争；回调不在队列锁内执行。

异步 producer 的 `send` 失败会沿 operation 抛错并收口，终止处理器只需在 `.cancelled` 时主动取消其 Task；不要在 `.failed` 回调里同步自取消，否则可能由计时子任务的 `CancellationError` 抢先掩盖真实容量错误。不能 await 的原生回调则应在 `offer` 失败时停止底层请求。

`payloadSize` 必须准确、非负地计量声明的载荷；SDK 不能替自定义类型证明内存大小。接入方不能在底层另建无界中间队列后依赖最外层 snapshot 宣称整体有界。

### 验证范围

新增测试覆盖有界队列、发送/消费取消与竞争、单消费者生命周期、三家 Provider 转换、原生网络回调溢出、运行身份关联、满队列完成结果、截止时间和执行/投递结果分离。它们使用离线 Engine/Transport 与 URLProtocol，不代表真实服务吞吐、进程 RSS、最低 OS 真机或 UI 已验收。
