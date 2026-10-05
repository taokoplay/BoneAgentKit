# Agent 级实时事件流

`BoneAgent.runEvents` 是显式 opt-in 的实时入口。它只在当前 Engine 实现真实的 `BoneInferenceEventStreaming` 时工作；只有 buffered streaming 或整段返回的 Engine 会在调用前 fail closed，不会把完整响应伪装成文本 delta。

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

流抛出错误时，之前收到的 delta 只能作为未完成草稿。不要把已显示的正文拼接后当作正式 Assistant 消息。取消会向下传递到 Provider event stream；Tool 或 native runtime 的协作式清理完成之前，Agent 不会释放运行所有权。

裸 `AsyncThrowingStream` 的消费方应取消持有消费任务来停止生产。`break` 不应被理解为强制终止所有底层工作；对于需要显式停止按钮的产品，应由 Host 持有并管理自己的 Task/Run handle。

既有安全 `BoneAgentEvent` 保持不变：它仍只包含 `runStarted`、Tool 生命周期和安全 `runFinished`，不会混入正文、reasoning、Tool 参数或 continuation。实时流也不进入日志、模型快照或普通 Workflow checkpoint。

## Provider 和本地模型边界

OpenAI、Anthropic、Gemini 当前已有 provider-neutral 增量事件。约束输出或结构化结果在验证完成前可能没有 `textDelta`，这是预期行为；Agent 不会从未经验证的 delta 自行重建 JSON 或 Tool Call。

本地 Llama 当前只有整段 `generate` 返回和模型状态通知，没有安全的 token/delta runtime seam。因此 `BoneLlamaInferenceEngine` 不承诺 `runEvents`。后续若增加本地实时能力，应新增可选 runtime streaming 协议，并处理 Unicode 分片、stop string 缓冲、reasoning marker、Tool envelope、约束输出、取消和单一终态；不能直接把原始 runtime token 当作公开正文。

实时流不改变普通 `run`、buffered streaming、Workflow 或 `BoneAgentConversation` 的现有语义。跨 Run 会话仍只在成功的完整用户 Turn 后更新，实时 delta 不会提前写入私有会话状态。
