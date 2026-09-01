# BoneAgentLlama Protocol Adapter Design

**Date:** 2026-09-01
**Status:** Approved

## Goal

新增独立 `BoneAgentLlama` Product，在不链接真实 llama.cpp 二进制的前提下，稳定 Runtime seam、真实 load/smoke Probe、Prompt 编码和 `BoneInferenceEngine` 文本推理映射。

## Module Boundary

`BoneAgentLlama` 依赖 `BoneAgentKit` 和 `BoneAgentLocalRuntime`。它不导入 C `llama` Module；后续 `BoneAgentLlamaCpp` 或 Binary Target 实现 `BoneLlamaRuntime`。Core、LocalRuntime 和 Host 都不感知 llama.cpp C API。

## Runtime Contract

Runtime 通过 actor-safe、Sendable 协议提供 runtime version、load、generate、smokeTest、cancel 和 unload。配置来自 `BoneLocalRuntimePlan`；generation options 来自 BoneInference generation options，经 Adapter 安全夹紧。错误为类型化 `BoneLlamaRuntimeError`，不暴露路径或底层 C 字符串。

## Prompt Encoding

Prompt 编码由 `BoneLlamaPromptEncoding` 注入。第一批提供通用 ChatML encoder，支持 system、user 和 legacy assistant 文本，追加 assistant 起始标记。它拒绝 available tools、tool result、assistant structured/tool calls、provider continuation、structured response、非隐藏 reasoning disclosure 和空消息，不把不支持语义静默文本化。

Host 可提供其他模板，但业务人格、敏感数据规则和产品 Prompt 不进入默认 encoder。

## Inference Engine

`BoneLlamaInferenceEngine` 只声明 `.text`，不声明 Tool Calling、structured output、streaming 或 image generation。Engine 校验请求 model ID，编码 Prompt，按 plan 加载/复用模型，调用 Runtime generate，并返回 `.finish`。空输出、配置错误和 Runtime 错误映射为 `BoneLlamaAdapterError`。

Engine 内部通过 actor Session 串行化 load/generate/cancel/unload。第一批不实现 KV cache 跨请求历史或多模型共享 Session。

## Runtime Probe

`BoneLlamaRuntimeProbeAdapter` 实现 `BoneLocalRuntimeAdapterProbing`：

- `.load`：load 后立即 unload，返回 modelLoad 检查。
- `.smoke`：load → smokeTest → unload，返回 smoke 检查。
- 错误映射为 incompatible、temporarilyUnavailable、unsupported 或 failed。

Probe 每次使用 Runtime factory 创建隔离实例，避免诊断改变生产 Engine 的加载状态。

## Testing

使用 Synthetic Runtime actor 验证调用顺序、配置映射、Probe 错误、Prompt fail-closed、Engine capabilities、model mismatch、文本响应、空响应与 Swift 6 并发安全。测试不需要真实 GGUF 或 llama.cpp。

## Non-goals

不链接 llama.cpp；不复制 Shorthand C bridge；不加入业务 Prompt；不支持 Tool Calling、structured output 或伪 Streaming；不修改 Shorthand；不发布版本。
