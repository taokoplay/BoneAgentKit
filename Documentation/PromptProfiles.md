# 业务提示词 Profile

`BonePromptProfile` 为下游 Host 提供可复用的业务角色、规则和回答风格配置。它是纯值类型，只负责校验、稳定排序和编译 system 消息，不读取文件、不访问网络、不持有 Agent 或授权状态。

## 适用场景

常见接入方式可以用 Profile 表达固定业务角色，例如个人 AI 助理、软件开发助手、客服或内部知识助手。用户问题、文件正文、搜索结果和工具结果属于运行数据，应继续作为 user、assistant 或 tool 消息传入，不应拼进可信 Profile。

## 基本用法

```swift
let profile = BonePromptProfile(
    id: "software-developer",
    version: 1,
    sections: [
        .init(id: "identity", content: "你是软件开发助手。", order: 10),
        .init(id: "style", content: "先说明原因，再给出可验证的实现。", order: 20)
    ]
)

let conversation = try await agent.makeConversation(
    modelID: "model-id",
    bindingID: "provider-site",
    systemMessages: [
        .init(role: .system, content: "Host 的工具和权限约束。")
    ],
    promptProfile: profile
)
```

一次性 Run 可以使用同名参数

```swift
let result = try await agent.run(
    modelID: "model-id",
    messages: [.init(role: .user, content: "检查这段代码。")],
    promptProfile: profile
)
```

## 编译规则

- `id`、section ID 使用有限 ASCII 标识符，便于日志诊断和稳定迁移。
- section 按 `order`，再按 ID 的 ASCII 顺序排序。
- Profile section 会编译成带有 `## section-id` 标题的单条前置 system 消息。
- 已有前置 system 消息会放在 Profile 后面，并与 Profile 合并为一条消息。
- 非前置 system 消息保持原有顺序，不会被移动或重写。
- Profile 正文、单个 section 和最终合并消息都有 UTF-8 字节上限。超过上限时整个组装失败，不截断正文。
- 空 Profile 返回原有消息序列，不改变旧调用行为。

合并为单条 system 消息是为了兼容要求单个 system 指令的 Provider。Provider 层继续接收已经归一化的消息，不需要了解 Profile。

## 会话与恢复

调用 `makeConversation` 时，Profile 会编译成会话初始 system 消息，并由现有会话私有状态保存。恢复时读取已保存的消息，不会根据磁盘上当前版本的 Profile 重新生成历史前缀。

Profile 内容改变会改变新会话的 system 前缀。应用应在没有未决请求、工具副作用或恢复操作时建立新会话。正在使用的会话继续使用创建时保存的前缀。

当前 SDK 没有修改 `BoneInferenceRequest` Schema，也没有把 Profile 放入 `BoneAgentConfiguration`。旧的 `systemMessages`、`run(request:)` 和直接构造 `BoneInferenceRequest` 的调用方式继续可用。

## Workflow 和动态事实

Workflow Host 应在冻结一次执行输入时编译 Profile，并把结果作为该次执行的消息输入。普通 checkpoint 不应保存 Profile 正文、用户输入或工具结果。恢复时应沿用 Host 已保护的输入身份和执行快照。

按请求变化的工具范围、资源权限、搜索域名和文件引用属于动态事实。它们应由 Host 根据当前已生效的工具和权限生成，并在调用 Profile 编译后作为受控 system 约束或当前 user 数据加入。Profile 文本不能授予工具权限，不能替代 Tool Registry、预算、授权和效果管线。

## WorkflowRunnerDemo

Demo 设置页提供三种角色模式

- `自定义助手` 保持旧版本行为，只使用现有的自由文本 `systemPrompt`。
- `个人 AI 助理` 使用 `personal-assistant` Profile。
- `软件开发助手` 使用 `software-developer` Profile。

自由文本说明仍然保留，并会与 Profile、资源规则、联网规则合并为单条 system 消息。聊天会话、Workflow 和结构化输出服务都从同一份设置生成 Profile。设置变化会更新现有的会话绑定指纹，保存对话的应用会按既有策略创建新会话。

Profile 文本会增加每次新请求的输入上下文，可能减少可用于用户历史和模型输出的 Token，并增加 Provider 费用。Demo 只在会话创建或独立请求构造时编译一次，不会在每个 Tool Step 重复注入。
