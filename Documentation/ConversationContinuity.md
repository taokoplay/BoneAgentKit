# 跨 Run Conversation Session

`BoneAgentConversation` 为需要连续多次用户交互的 Host 提供显式的会话状态容器。它把一轮成功完成的用户消息、保留的历史、上下文压缩摘要和 Provider continuation 交给下一次新的 Run 使用；它不是 Workflow checkpoint，也不是中断 Run 的自动恢复器。

## 适用边界

- `makeConversation` 创建一个新的会话实例；会话初始 revision 为 `0`，只包含调用方提供的 system 消息。
- 每次 `send` 都创建一个新的 Run，使用当前 `BoneAgentConfiguration` 中的 Run budget。成功的模型终态才会把用户消息和最终 assistant turn 发布到会话状态，并将 revision 加一。
- Tool Call、Tool Result 和 Provider continuation 只在当前 Run 内按正常 Agent Loop 执行；成功完成后，已完成的 Tool 交换可以作为历史传给下一次 Run，但 Tool 不会因为导入历史而重新执行。
- 默认仍由上下文管理配置决定是否压缩。已保存的摘要会在恢复后的下一次 Run 中继续作为不可信的历史数据使用，不会升格为 system 指令或授权依据。
- `exportPrivateState()` 只导出显式私有状态。返回值可能包含 prompt、Tool payload、Tool Result、摘要和 Provider opaque continuation，不能写入普通日志、普通 Workflow checkpoint 或发送到其它 Provider/连接。

## 创建与连续发送

```swift
let conversation = try await agent.makeConversation(
    modelID: "provider-model-id",
    bindingID: "host-provider-binding-v1",
    systemMessages: [
        .init(role: .system, content: "Follow the product policy supplied by the host.")
    ],
    generationOptions: .init(temperature: 0.2, maximumOutputTokens: 512)
)

let first = try await conversation.send("第一条用户消息")
let second = try await conversation.send("基于上一轮继续处理")
```

`bindingID` 不是 URL、凭据或授权令牌，而是 Host 为具体 Provider 站点、账号范围或本地 Runtime 配置分配的不透明稳定标识。恢复时必须传入同一 `modelID` 和 `bindingID`，并且当前 Agent 的完整 Tool definition 集合必须与快照一致。

## Host 持久化与恢复

SDK 不自动把会话写盘，也不负责加密、真实性、所有权或跨进程 CAS。Host 应把 `id`、`revision` 和私有 blob 放在受保护的私有存储中，并在启动一次新的会话 Run 前完成：

1. 验证 blob 的来源、完整性、当前会话所有权和 schema 版本。
2. 确认没有尚未结束的 Run、未知的 Tool/Effect 提交或待 reconciliation 的 in-flight marker。
3. 按 CAS 读取最新 revision；只有成功得到新 blob 后，才把它写回并将 revision 更新为下一个值。
4. 如果 Provider 调用或副作用状态未知，不要依据旧 blob 直接重试。先由 Host 对账；无法确认时保持会话处于业务侧 recovery 状态。

示例：

```swift
let blob = try await conversation.exportPrivateState()
let conversationID = await conversation.id
let revision = await conversation.revision
try hostPrivateStore.put(blob, id: conversationID, revision: revision)

let restored = try await agent.restoreConversation(
    privateState: hostPrivateStore.read(id: conversationID, revision: revision),
    modelID: "provider-model-id",
    bindingID: "host-provider-binding-v1",
    expectedID: conversationID,
    expectedRevision: revision
)
let result = try await restored.send("恢复后的新用户消息")
```

上例中的 `put`、读取、加密和 CAS 是 Host 伪代码，不是 SDK 提供的持久层。`expectedID` 与 `expectedRevision` 用于阻止调用方把旧快照误当成当前会话状态；它们不能证明网络调用或外部副作用已经成功。

## 生命周期与失败语义

会话 phase 为 `ready`、`running` 或 `recoveryRequired`：

- 同一实例只允许一个 `send`；发送期间再次 `send` 或导出会返回 `busy`。
- 用户取消、Provider 错误、预算耗尽、Tool 执行失败、continuation 无法重绑定或最终私有状态校验失败，都会将该实例锁定为 `recoveryRequired`。SDK 不提供隐式重试，也不会把失败 Run 的部分历史发布为新 revision。
- 成功结果一旦完成 Agent 的成功线性化点，后续迟到的取消不会回滚已发布的会话状态。Host 仍应以返回的私有 blob 和 revision 为准完成 CAS 写入。
- 一个过大的单条用户消息、必须保留的历史或摘要输入可能稳定超过预算；当前版本不会自动分块摘要，也不保证摘要事实保真。
- 私有状态上限为 8 MiB，单条用户消息上限为 1 MiB，历史最多 10,000 条消息，摘要正文最多 65,536 个 UTF-8 字节。超限应由 Host 处理为业务错误，而不是裁剪私有内容后继续。

## Provider 与模型限制

Provider continuation 是不透明、Provider 绑定的数据。当前 Gemini 会验证并重绑定包含 `thoughtSignature` 的精确 assistant turn；裁剪、移动或改写已签名 turn 时会 fail closed。OpenAI、Anthropic 和不提供 continuation 的本地 Llama 使用各自正常的消息历史约束。模型、站点绑定、Tool schema 或上下文策略发生不兼容变化时，应新建会话或先完成 Host 侧迁移，不能强行解码后发送。

上下文压缩与会话连续性是两个层次：压缩的摘要调用计入当前 Run 的推理、输入/输出、费用、取消和 wall-clock budget；会话 revision 只在用户 Turn 成功完成后推进。普通 Agent Run、Workflow checkpoint、事件 sink 和模型快照仍不会包含私有 prompt、Tool payload、摘要正文或 continuation。

## 当前未承诺的能力

- 跨进程自动发现和恢复未完成 Run；
- 对 Provider 已接受但 Host 尚未收到回执的请求进行通用去重；
- 强制终止 native Llama runtime；
- 分块摘要、事实保真证明或自动摘要审校；
- 把 Conversation Session 自动绑定到 Workflow 的持久状态或业务数据库。

这些责任必须由 Host 根据自己的加密、授权、Effect、审计和恢复协议实现。
