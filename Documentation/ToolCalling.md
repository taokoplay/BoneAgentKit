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

## 本地模板与 Tool Envelope

本地 Llama 的模型会话模板与 Tool wire envelope 是两个独立职责：`BoneLlamaConversationBuilder` 先建立不含 ChatML、Qwen 或 Hermes 标记的规范化消息，随后由且仅由一个 `BoneLlamaConversationRendering` 渲染最终 Prompt。调用方必须在 `BoneLlamaChatMLConversationRenderer` 与 `BoneLlamaNativeTemplateRenderer` 中选择一条路径；Native 路线要求具体 Runtime 实现 `BoneLlamaNativeTemplateRenderingRuntime`，缺失时失败关闭，不静默套用 ChatML。

`BoneLlamaToolEnvelopeCoding` 只负责 Tool 指令、Assistant Tool Call 历史、Tool Result、生成约束和严格输出解码，不渲染会话模板。`BoneLlamaConstrainedJSONToolEnvelopeCodec` 使用可被 Grammar 约束的判别联合：

```json
{"type":"final","content":"Answer"}
```

或：

```json
{"type":"tool_calls","tool_calls":[{"id":"call-1","name":"echo","arguments":{"value":"hello"}}]}
```

约束生成只提高结构合法性，不替代 Registry、Tool Schema、Impact Policy、授权和预算校验。`.maximumTokens` 终止不会进入 Envelope Decoder，避免交付半截 JSON。`reasoningDisclosure` 对本地 Llama 仍只允许 `.hidden`。

alpha.6 的 `BoneLlamaToolCalling` / `BoneLlamaJSONToolCallingCodec` 组合入口继续兼容，但它已经包含完整 ChatML 模板，不能再与 Native Renderer 叠加。新接入应使用独立 Renderer + Envelope。

## 云 Provider Output Constraint

`BoneInferenceOutputConstraint` 与 Tool Calling 是不同请求语义。当前首版要求 `responseFormat == .text` 且 Tool Catalog 为空，避免未定义的“Tool Call 或受约束 Final”联合。Enum 通过固定 `{"value": ...}` 包装映射到 Provider 原生 JSON Schema，返回后逐字节精确匹配；JSON Schema 同样包装任意 JSON value，并在 SDK 边界再次验证。不得 trim、大小写折叠、抽取外壳或修复 JSON。

官方 Provider 映射为：OpenAI `response_format.json_schema`、Gemini `generationConfig.responseSchema`、Anthropic `output_config.format.json_schema`。只有官方 Provider kind、受支持 Schema 方言和精确 `.providerSmoke` 身份匹配时才授予 `.constrainedOutput`；兼容端点和 bundled Catalog 中没有真实 Smoke 身份的模型继续联网前失败。云端不使用本地 Chat Template、Tool Envelope、Tokenizer 或 Prefill 身份。

## Provider wire

- OpenAI：完整 Assistant `tool_calls` 历史，随后按 call ID 回传多条 `role=tool`；
- Anthropic：Assistant `tool_use` blocks，随后一条 user message 包含多个 `tool_result`；
- Gemini：model `functionCall` parts，随后 user `functionResponse` parts。Google `thoughtSignature` 和原始 model parts 仅作为 Provider-scoped continuation 原样重放。

Streaming 只交付完整终态：OpenAI 需要语义 finish 和 `[DONE]`；Anthropic 需要 block stop、stop reason 与 `message_stop`；Gemini 使用 `streamGenerateContent?alt=sse` 并要求明确 `finishReason`。损坏、截断、跨 Provider continuation 在联网前 fail-closed。

## 调度

同轮多个 Tool Call 默认按 Provider ordinal 串行。只有 Tool 显式声明普通公开只读、`parallelSafe`、资源 key 无冲突且 Host 开启有界并发时才并行；任何写操作永远串行。结果始终按 ordinal 聚合，不按完成时间。取消后迟到结果不得写入历史或 Checkpoint。

## 授权

Tool 使用六维影响：数据访问、外部传输、状态变化、经济影响、用户可见影响、权限变化。未知影响、缺 Handler 或超出 Host Policy 都拒绝。高风险调用使用一次性 `BoneAuthorizationGrant`，绑定 Run/Step/Attempt/Call、Tool/schema 版本、canonical arguments SHA-256、principal、resource scope/revision、影响维度、有效期与 nonce。执行前重验，防止 TOCTOU。

真实 OpenAI、Anthropic、Gemini Tool Calling 与 Output Constraint 必须通过真实 Provider/真机 Smoke；自动 Contract 只能证明 SDK 映射和失败关闭，不能替代具体在线模型验收。Anthropic Structured Outputs 可能独立缓存 Schema，调用方不得把 PHI、密码、Token、完整卡号或其他个人敏感值放入属性名和 enum 候选；这些值只能位于受正常数据政策保护的消息/响应内容中。
