# BoneLlama Runtime State Observation Design

**Date:** 2026-09-01
**Status:** Approved

## Goal

让 Host 页面无需轮询即可获知本地模型加载、生成、取消、卸载的开始、完成或失败，同时保留按需查询当前状态的能力，并确保状态数据不泄露模型路径、Prompt、输出、下载凭据或底层 C API 文本。

## State Model

`BoneAgentLlama` 新增类型化状态：

- `notLoaded`
- `loading`
- `loaded`
- `generating`
- `cancelling`
- `unloading`
- `failed`

稳定状态本身表达完成，不增加容易被慢订阅者漏掉的瞬时 `completed`：

- `loading → loaded` 表示加载完成；
- `generating → loaded` 表示生成完成且模型仍驻留；
- `unloading → notLoaded` 表示卸载完成；
- 任一操作进入 `failed` 表示失败。

每个 Snapshot 带单调递增 `revision`、Runtime version、可选配置摘要和类型化失败原因。Runtime Snapshot 不带 model ID；Engine 投影为带固定 `modelID` 的 `BoneLlamaModelState`。

## API Layers

### Runtime compatibility

保持现有 `BoneLlamaRuntime` 协议不变，避免破坏已有 Synthetic Runtime 和未来其他 Adapter。新增可选协议 `BoneLlamaRuntimeStateObserving`：

- `currentRuntimeState() async -> BoneLlamaRuntimeState`
- `runtimeStateUpdates() async -> AsyncStream<BoneLlamaRuntimeState>`

`BoneLlamaCppRuntime` 实现该协议。未实现该协议的 Runtime 仍可由 Engine Session 根据自身调用边界投影状态。

### Engine API

`BoneLlamaInferenceEngine` 正式提供：

- `currentModelState() async -> BoneLlamaModelState`
- `modelStateUpdates() async -> AsyncStream<BoneLlamaModelState>`

新订阅者立即收到当前 Snapshot。状态流采用 `bufferingNewest(1)`；慢订阅者只保留最新状态，不积压历史。订阅取消时移除 continuation；Engine/Session 释放时结束全部流。

## State Transitions

Engine Session 在操作边界发出状态：

```text
notLoaded → loading → loaded
a loaded → generating → loaded
loaded/generating → cancelling → loaded
loaded → unloading → notLoaded
operation failure → failed
failed → loading (retry)
failed/loaded → unloading → notLoaded
```

`infer` 首次调用时会先发出 `loading`，加载成功后发出 `loaded`，随后发出 `generating`。Runtime 错误映射为类型化失败状态后继续抛给调用方。若生成失败但模型原生状态仍完整，首版仍保守进入 `failed`；Host 可显式 unload 或下一次 infer 触发重新加载。

## Runtime Truth and Engine Projection

Engine 的 Session 是 Host 公开状态的唯一序列化来源，保证 Engine 操作和页面状态顺序一致。若 Runtime 实现 `BoneLlamaRuntimeStateObserving`，首版不在 Engine 内再次订阅 Runtime 流，避免双源竞争；Runtime 流主要供诊断、Probe Test Host 或直接 Runtime 消费者使用。Engine 状态机在自己的 load/generate/cancel/unload 边界投影相同语义。

## Cancellation Semantics

当前 Runtime actor 的同步生成循环不能在同一个 actor 上并发执行 `cancel()`；这是既有限制，不在本状态功能中伪称已解决。Engine 收到 cancel 调用时发出 `cancelling`，调用 Runtime cancel，随后按 Runtime 实际结果回到 `loaded` 或进入 `failed`。真正的低延迟跨任务取消需要后续把原生生成移出 actor executor或引入线程安全原生取消标志。

## Privacy and Security

状态中禁止包含：

- 模型绝对路径或文件 URL；
- 下载 URL、Token 或可信 Host 之外的来源细节；
- Prompt、模型输出或 Token piece；
- llama.cpp 原始日志和 C API 错误字符串。

失败只暴露 `BoneLlamaRuntimeError`。配置只包含 context、batch 和 thread 等运行预算。

## UI Contract

Host 页面通过 `.task` 订阅：

```swift
for await state in engine.modelStateUpdates() {
    modelState = state
}
```

页面可显示“正在加载”“本地模型已就绪”“正在生成”“生成完成”“正在卸载”“已卸载”“操作失败”。首版不提供虚假加载百分比；llama.cpp Bridge 当前没有稳定、跨版本的权重加载进度契约。

## Testing

- Snapshot 的值语义、revision 和隐私字段边界；
- 新订阅立即回放当前状态；
- 多订阅者收到相同有序变化；
- load/generate/unload 完成序列；
-失败序列和错误映射；
-订阅取消与 continuation 清理；
-旧 Runtime 不实现观察协议仍可通过 Engine 工作；
-`BoneLlamaCppRuntime` 真实 GGUF 状态序列；
-物理 iPhone 页面实时收到开始和完成状态。

## Non-goals

不提供加载百分比、Token Streaming、跨进程状态、持久状态恢复或真正的即时取消；不把 UI 文案放入 Package；不修改 ParsingBook 或 Shorthand Host；不发布版本。
