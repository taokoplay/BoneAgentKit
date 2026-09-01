# Local Runtime Probe Design

**Date:** 2026-09-01
**Status:** Approved

## Goal

为本地模型提供统一、可解释的两阶段健康探测：`BoneAgentLocalRuntime` 做安装、Artifact、格式签名、版本、设备和运行计划预检；独立 Adapter 做真实 Runtime availability、模型加载及可选 smoke probe。

## Architecture

探测分两层：

1. **Static metadata probe**：LocalRuntime 验证 Store 安装状态、可选完整 SHA-256、格式签名、Adapter 支持格式、Adapter 版本、内存和 Runtime Plan。
2. **Adapter runtime probe**：LocalRuntime 调用注入的 `BoneLocalRuntimeAdapterProbing`。llama.cpp、Foundation Models 等 Adapter 自行解释架构/量化和真实加载结果，不把平台 Framework 引入 Core。

统一编排器生成 `BoneLocalRuntimeProbeReport`，Host 不再根据任意字符串猜测可运行性。

## Probe Depth

- `metadata`：只执行静态预检，不调用 Adapter 的真实加载。
- `load`：静态预检通过后调用 Adapter 加载模型并立即释放。
- `smoke`：Adapter 可选执行最小 tokenize/decode 或平台等效动作；不传业务 Prompt，不返回或持久化生成内容。

Adapter 必须声明支持的最大 Probe depth。请求更深能力时返回 `unsupported` 检查，而不是隐式降级。

## Adapter Contract

Adapter descriptor 包含稳定 `id`、runtime version、支持格式、runtime constraints 和 maximum probe depth。Adapter probe 接收模型、Artifact URL、Environment、Runtime Plan 与 depth，并返回类型化结果；不返回底层异常文本或绝对路径。

## Artifact Inspection

Core 只做最小、稳定的格式签名检查：

- GGUF 文件前四字节必须是 ASCII `GGUF`。
- 文件大小和 SHA-256 继续复用 Store。
- Core 不解析 GGUF metadata、tensor、tokenizer 或 architecture；这些属于 llama.cpp Adapter 的真实兼容性。

## Report and Privacy

Report 只包含：model ID、adapter ID、depth、总体状态和有序 checks。检查结果分类：

- `passed`
- `corrupted`
- `incompatible`
- `temporarilyUnavailable`
- `unsupported`
- `failed`

总体状态使用最严重检查项确定，且 fail closed。Report 不含绝对路径、URL 查询参数、Prompt、模型输出、Token 或底层错误描述。

## Failure Mapping

- 未安装、大小/SHA/签名错误：`corrupted`
- 格式不匹配、runtime version 不足、Adapter 拒绝架构：`incompatible`
- 内存不足或系统模型尚未准备：`temporarilyUnavailable`
- SDK/设备永久不支持、Probe depth 不支持：`unsupported`
- 未知真实加载失败：`failed`
- 全部检查通过：`compatible`

## Boundaries

`BoneAgentLocalRuntime` 负责统一契约、静态检查、编排和安全报告；`BoneAgentLlama`/`BoneAgentFoundationModels` 后续负责平台真实 Probe。Host 负责何时执行昂贵 Probe、热状态策略、用户文案和报告上传策略。

本批不链接 llama.cpp，不引用 FoundationModels，不实现 GGUF 完整解析，不执行真实模型生成，不修改 Shorthand。
