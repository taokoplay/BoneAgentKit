# Tool Calling

## 统一事实模型

`BoneInferenceResponse.assistantTurn` 是完整 Assistant Turn：ordered text、structured output、0...N Tool Calls、finish reason、usage、refusal 和 Provider continuation 属于同一个终态。旧 `.finish`、`.structured`、`.toolCall` 仅是兼容投影，不建立第二套执行语义。

Tool arguments 必须是 JSON object。单个 arguments 上限 1 MiB，同轮总 arguments 上限 4 MiB，最多 32 个 Tool Calls。重复 call ID、空 Turn、数组或标量参数、无关联 Tool Result 都稳定拒绝。

兼容旧单 Tool 历史时，`BoneInferenceMessage.toolResult` 会重新校验 call ID、Tool ID、JSON 内容和 1 MiB 上限，因此该工厂是 throwing API：

```swift
let message = try BoneInferenceMessage.toolResult(
    callID: callID,
    toolID: toolID,
    result: resultData
)
```

旧调用方升级时必须显式处理 `BoneInferenceError.invalidToolResult` 与 `.toolResultTooLarge`。这是有意的源码破坏性收紧：无法通过校验的数据不得伪装成 Tool 成功历史，也不得以 `try!` 终止宿主 App。

## Provider wire

- OpenAI：完整 Assistant `tool_calls` 历史，随后按 call ID 回传多条 `role=tool`；
- Anthropic：Assistant `tool_use` blocks，随后一条 user message 包含多个 `tool_result`；
- Gemini：model `functionCall` parts，随后 user `functionResponse` parts。Google `thoughtSignature` 和原始 model parts 仅作为 Provider-scoped continuation 原样重放。

Streaming 只交付完整终态：OpenAI 需要语义 finish 和 `[DONE]`；Anthropic 需要 block stop、stop reason 与 `message_stop`；Gemini 使用 `streamGenerateContent?alt=sse` 并要求明确 `finishReason`。损坏、截断、跨 Provider continuation 在联网前 fail-closed。

## 调度

同轮多个 Tool Call 默认按 Provider ordinal 串行。只有 Tool 显式声明普通公开只读、`parallelSafe`、资源 key 无冲突且 Host 开启有界并发时才并行；任何写操作永远串行。结果始终按 ordinal 聚合，不按完成时间。取消后迟到结果不得写入历史或 Checkpoint。

## 授权

Tool 使用六维影响：数据访问、外部传输、状态变化、经济影响、用户可见影响、权限变化。未知影响、缺 Handler 或超出 Host Policy 都拒绝。高风险调用使用一次性 `BoneAuthorizationGrant`，绑定 Run/Step/Attempt/Call、Tool/schema 版本、canonical arguments SHA-256、principal、resource scope/revision、影响维度、有效期与 nonce。执行前重验，防止 TOCTOU。

真实 OpenAI、Anthropic、Gemini Tool Calling 必须通过真机 Smoke；自动 Contract 不能替代真实 Provider 验收。
