# Agent 统一运行状态

## 接入方式

`BoneAgentConfiguration.statusSink` 接收无正文的运行状态快照。普通 `run`、buffered streaming、`runEvents`、`runUntilBoundary` 和 `BoneAgentConversation.send` 共用同一入口，不需要客户端分别拼接压缩、工具和模型回调。`agent.currentStatus` 可异步读取最新快照；首次接受 Run 之前为 nil，结束后保留最后终态，下一次 Run 会换一个 `runID`。

```swift
import BoneAgentKit

func makeObservedAgent(
    engine: any BoneInferenceEngine,
    render: @escaping @MainActor @Sendable (BoneAgentStatus) -> Void
) throws -> BoneAgent {
    let configuration = try BoneAgentConfiguration(
        maximumSteps: 12,
        contextManagement: .init(),
        statusSink: .init { status in
            await render(status)
        }
    )
    return try BoneAgentBuilder(inferenceEngine: engine)
        .withConfiguration(configuration)
        .build()
}
```

同一套配置既支持 `agent.run(request:)`，也支持从 `agent.makeConversation` 创建的会话。状态回调默认不做任何事；现有构造调用无需提供新参数。`runEvents` 继续通过自己的流提供正文 delta、工具事件和正式结果，状态不混入这些既有 enum，不要求调用方修改旧的穷尽 switch。

## 阶段与展示含义

| `status.phase` | 建议展示 | 触发依据 |
| --- | --- | --- |
| `preparingInput` | 准备输入 | Run 已受理，正在构造和校验输入 |
| `checkingBudget` | 检查上下文与预算 | 检查完整请求及 Run 额度，可能在同一步再次出现 |
| `compactingContext` | 压缩上下文 | 实际达到触发阈值，开始裁剪/复验候选；不表示已经删掉历史 |
| `summarizingContext` | 生成历史摘要 | 摘要预检通过，即将调用显式摘要 Engine |
| `resolvingImages` | 读取并校验图片 | 图片数量、字节和 Token 预检通过，开始读取冻结引用 |
| `waitingForModel` | 模型处理中 | 正在调用 Engine；内置 Provider 在发送前也上报此阶段 |
| `reasoning` | 思考中 | 收到 Provider 的明确推理信号；不按时间或模型名称推测 |
| `generatingResponse` | 正在生成回复 | 收到公开文本的流式信号，包括暂未对外展示的约束输出 |
| `generatingToolCall` | 正在生成工具调用 | 模型正在形成工具调用，不代表工具已经执行 |
| `validatingResponse` | 校验模型结果 | 正在聚合/校验响应或处理完整响应，可能最终失败 |
| `preparingTools` | 准备工具 | 工具参数、权限、执行上下文及管线准备 |
| `executingTools` | 执行工具 | 已进入工具执行闭包；仍可能取消或失败 |
| `processingToolResults` | 整理工具结果 | 当前活动工具已返回/退出，正在整理结果或调度后续工具 |
| `finished(.succeeded)` | 已完成 | 已达到本次请求的 Agent 停止边界 |
| `finished(.failed(error))` | 执行失败 | 固定 `BoneAgentError` 分类，没有底层错误正文 |
| `finished(.cancelled)` | 已取消 | 执行/清理已退出，取消终态已交付 |

每条快照包含 `runID`、Run 内从 1 递增的 `sequence`、可选的 1 起始 `step`、`phase` 与 `activeTools`。并行工具列表按 ordinal 排序，每项只有 callID、toolID、ordinal 和 preparing/executing；一个工具结束时其他工具仍保留。失败或取消终态清空活动列表，不表示未知副作用已经恢复或可以重试。工具结果的成功/失败细节仍通过既有 Tool Result 与实时 `toolResultReady` 契约处理，状态快照不携带结果正文。

UI 应用 `runID` 和 `sequence` 防止自身异步渲染队列把旧状态覆盖到新 Run。阶段/步骤/活动工具未变但 `tokens` 统计变化时也会投递，默认合并 100 ms 内的高频统计变化；阶段、请求完成及终态立即刷新，计数不丢失。无后台刷新任务，主动查询可读取未合并的当前值。状态顺序允许“压缩 → 摘要 → 继续压缩 → 检查预算”和各轮推理/工具循环。明细有界而累计完整，配置及边界见 [Token 与会话统计](TokenStatistics.md)。

## 思考状态与正文披露分离

OpenAI、Anthropic、Gemini 的实时流在 `reasoningDisclosure = .hidden` 时仍可上报 `reasoning` 状态，但不会额外泄露 `reasoningDelta`、思考原文、签名或 redacted payload。原实时流的 `reasoningStarted/Delta/Completed` 仍受披露配置约束。

只有真实收到对应信号才会显示思考阶段。普通非流式和 buffered streaming 在等待期间显示模型处理中，不会在完整响应返回后补发一段伪实时“思考过程”。Provider 未返回思考信号、模型没有这类能力或自定义 Engine 没有报告时，可能只观察到等待和校验。状态不提供进度百分比，也不证明远端任务确切执行到哪个内部算子。

自定义 Engine 可在实际边界调用以下可选接口，现有 `BoneInferenceEngine` 协议无需增加必需实现：

```swift
await BoneInferenceActivityReporting.report(.waitingForModel)
// 在实际接到推理信号时：
await BoneInferenceActivityReporting.report(.reasoning)
// 在实际接到公开文本时：
await BoneInferenceActivityReporting.report(.generatingResponse)
```

Agent 在每次模型调用周围设置 Task-local 的观察作用域，并以本次调用标识拒绝迟到通知。不同 Agent/请求隔离；结构化子任务和继承上下文的 `Task` 可上报，`Task.detached` 不继承。自定义 Engine 若只实现原有标准事件流，Agent 会从其事件更新阶段；采用显式 activity 报告的 Engine 应完整报告阶段，Agent 不再同时重放消费端的旧阶段。

直接调用 Provider 的 Host 也可使用 `BoneInferenceActivityReporting.withSink(_:operation:)`。单独的推理 sink 只有 Provider 阶段，不包含 Agent 压缩、工具或终态；统一 Agent sink 则由 SDK 串行投递完整快照。

## 时序、取消与边界

状态观察是 nonthrowing、逐条 await 的回调。同一 Run 内，即使并行工具导致交错，前一条回调完成后才调用下一条。回调可读取 `currentStatus`；它读取的是最新已产生的快照，可能比正在交付的回调更新。回调必须及时返回，不得等待同一 Run 或尚待回调放行的工具完成，否则会阻塞执行。UI 切换到 MainActor 即可，不需要在 SDK 内引入 UI 框架。

Run 预算计时启动后的回调耗时计入已有 wall-clock 预算。Agent 在新操作边界重新检查取消/预算。取消是协作式的，不能强制中断不配合的网络、工具或观察闭包。成功已经越过原有线性化点后，迟到取消不会将成功改写成取消；接受的 Run 只产生一个状态终态。忙碌拒绝、非法会话输入、`runEvents` 在返回流之前的能力拒绝等未受理调用不会创建新状态或替换正在运行的状态，调用方仍须处理抛出的错误。

`finished(.succeeded)` 表示到达所选 Agent 边界：`afterFirstToolTurn` 也属于成功停止，不等于任务最终回答已经完成。Workflow 的后续持久化提交、Host 审批等待/暂停/恢复以及其他外部业务状态仍以既有 Workflow 控制面为准；状态观察不代替 checkpoint、授权、预算事实或恢复判断。

图片预处理由 Host 在创建请求引用之前显式调用，因此不属于这次 Agent Run 的活动状态；Agent 覆盖发送时的图片读取和校验。接入方可为上传/预处理等 Run 之外的 UI 操作维护自己的状态。

## 数据边界与验证

快照没有提示词、回复文本、思考内容、Tool 参数/结果、图片引用、URL、凭据或原始错误；不自动 Codable，不进入普通日志、私有会话导出或 Workflow checkpoint。callID/toolID 仍属于关联元数据，Host 应按自己的日志策略处理。

`AgentStatusTests` 验证各运行方式、压缩和摘要前通知、回退、取消、重入、单终态、并行工具保留、旧调用迟到状态隔离和真实 Provider 适配器的隐藏思考链路。`InferenceActivityTests` 验证三家协议的状态/正文分离、图片预检、取消和调用作用域。测试使用离线 Transport，不代表线上模型或客户端 UI 已验收。
