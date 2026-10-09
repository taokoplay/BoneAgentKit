# 模型元数据与思考参数接入

本文说明 BoneAgentKit 如何读取 `models.dev` 的模型声明、如何把 Host 已核验的思考配置映射到 Provider wire，以及 OpenAI/Anthropic 思考内容如何在工具多轮中安全续接。

## 先区分三类事实

1. **外部目录声明**：`BoneModelMetadata` 保存模型名称、推理声明、工具/结构化输出声明、温度、模态、上下文/输入/输出限制、价格、状态和来源。它来自 `models.dev/api.json` 的已展开发布结果，并记录 GitHub 源提交 `c849cd11adf999db2203b20d3ab1fa8e58852e63`。
2. **Host 执行 profile**：`BoneModelCapabilityProfile` 和 `BoneInferenceReasoningProfile` 由 Host 针对确切渠道、模型、协议、端点和已验证 mapper 注入。外部目录的 `reasoning=true`、`tool_call=true` 或 `structured_output=true` 不会自动授予 SDK 的运行能力。
3. **本次请求**：`BoneInferenceGenerationOptions.reasoning` 只描述本次请求想采用的模式、档位和预算。`nil` 保持 Provider 默认行为；显式非法组合在 Transport 之前失败。

因此，目录可以帮助 UI 展示和 Host 选择候选，但不能替代供应商文档、网关契约、Provider Smoke 或真实端点验证。

## 模型目录来源与展开规则

项目对照时同时使用：

- 发布 API：<https://models.dev/api.json>
- 源库：<https://github.com/anomalyco/models.dev>

两者是同一发布管线的源代码与生成结果，不是两份独立执行证据。比较前必须按源库的生成规则展开 provider/model 继承、覆盖、`base_model_omit`、tier 和类型过滤，再逐字段比较。当前固定源提交和审计结果见 `.context/models-dev-audit/2026-10-09-cross-check.md`。

本地目录继续保留官方已核验的 `tokenLimits` 和执行 profile；只有取得对应厂商、对应渠道的明确证据才更新。近期确认的安全更新包括 DeepSeek V4 的 `1048576/393216`、Kimi K2.6 的 `262144` 上下文、GLM-5.2/5.1 的 `131072` API 输出上限、MiMo V2 Omni 的 `262144` 上下文以及 OpenAI `gpt-image-1` 的已公告弃用标志。Qwen Coder Plus 的阿里云官方页面仍为 `1000000/997952/65536`，不能为了匹配目录推断改成 `1048576`。MiMo Token Plan 与 MiMo 主 API 也不能互相套用。

## Host 注入 profile

下面是一个最小的、只用于请求校验和 wire 映射的例子。示例中的档位和预算必须来自 Host 对实际端点的官方核验，不应根据模型名称猜测。

```swift
let reasoningProfiles: [String: BoneInferenceReasoningProfile] = [
    "deepseek-v4-pro": .init(
        wireFormat: .thinkingType,
        modes: [.enabled, .disabled],
        effortValues: ["low", "medium", "high"],
        allowsTemperature: false,
        continuation: .reasoningContent
    ),
    "claude-with-thinking": .init(
        wireFormat: .anthropicBudget,
        modes: [.enabled, .disabled],
        budgetRange: 1_024 ... 64_000,
        allowsTemperature: false,
        continuation: .anthropicThinking
    ),
    "gemini-thinking": .init(
        wireFormat: .geminiBudget,
        modes: [.enabled, .disabled],
        budgetRange: 0 ... 32_768,
        allowsTemperature: true,
        continuation: .none
    )
]

let engine = BoneOpenAIInferenceEngine(
    configuration: providerConfiguration,
    transport: transport,
    modelReasoningProfiles: reasoningProfiles
)

let request = BoneInferenceRequest(
    modelID: "deepseek-v4-pro",
    messages: [.init(role: .user, content: "请检查这条记录")],
    generationOptions: .init(
        maximumOutputTokens: 4_096,
        reasoning: .init(mode: .enabled, effort: "high")
    )
)
```

实际初始化器还需要传入与 Host 已验证结果对应的 `modelCapabilityProfiles`、上下文限制和可选 `modelMetadata`。示例 profile 不是对供应商成功率的承诺，也不包含凭据。

## wire 映射矩阵

| profile wireFormat | 目标协议 | 请求字段 | 续接 | 说明 |
| --- | --- | --- | --- | --- |
| `openAIChat` | OpenAI Chat | `reasoning_effort` | 无/按 profile | 使用 `max_completion_tokens`；`nil` 保持默认 |
| `thinkingType` | OpenAI-compatible | `thinking.type`、可选 `reasoning_effort` | `reasoning_content` | 仅按 Host 注入 profile 开启 |
| `enableThinking` | OpenAI-compatible | `enable_thinking`、`thinking_budget` | 无/按 profile | 预算和开关组合由 profile 限制 |
| `anthropicBudget` | Anthropic Messages | `thinking.type=enabled`、`budget_tokens` | `thinking` / `redacted_thinking` 完整块 | budget 必须至少 1024 且小于本次 `max_tokens`；强制 Tool fallback 不与 thinking budget 混用 |
| `anthropicAdaptive` | Anthropic Messages | `thinking.type=adaptive`、`output_config.effort` | 依 profile | 不再同时传固定 budget |
| `anthropicCompatible` | Anthropic-compatible | 兼容端点声明的 `thinking` / `output_config` | 仅 profile 声明的格式 | 兼容协议不会自动升级为官方能力 |
| `geminiBudget` | Gemini | `generationConfig.thinkingConfig.thinkingBudget` | 保持现有 `thoughtSignature` 机制 | 不把 Gemini signature 转成 OpenAI/Anthropic envelope |
| `geminiLevel` | Gemini | `thinkingConfig.thinkingLevel` | 保持现有机制 | 使用官方枚举的大小写形式 |

OpenAI Responses API、`reasoning_details`、Anthropic beta header 和 Gemini 非公开字段不在本次实现范围。不要把 `models.dev` 的 `interleaved` 字段直接转成请求 header。

## 校验与错误边界

- reasoning 只有在 `BoneInferenceReasoningProfile` 存在时才可显式发送；未知模型不会因名称相似而推断协议。
- `mode`、`effort`、`budgetTokens`、`temperature` 和协议格式在构造 URLRequest 前检查；非法组合抛出 `BoneInferenceReasoningConfigurationError`，不静默删除参数。
- metadata 的 `false` 只能收紧能力；metadata 的 `true` 或缺省值不能授予 Tool Calling、结构化输出、约束输出或固定 token 限制。
- 旧的 `serverReasoning` 行为仍保留兼容路径；如果同时传入显式 reasoning 与互相冲突的 legacy 设置，则失败而不是选择一方。
- Llama 和其它没有实现该 wire 的引擎对显式 reasoning fail closed。

## OpenAI / Anthropic continuation

只有 profile 明确声明对应 continuation 时，SDK 才把供应商私有思考 payload 放入有界 `BoneInferenceProviderContinuation`：

- OpenAI 保存 `reasoning_content` 的完整拼接内容。
- Anthropic 保存 thinking、signature、redacted thinking、text 和 tool_use 的完整原始块顺序。
- continuation 绑定 provider kind、端点配置摘要、模型、wire format、continuation 类型和 reasoning options；绑定失败时不重放。
- assistant turn 还绑定前置 user anchor。上下文压缩只允许完整删除 user turn 并安全重索引，不能保留已改写或缺失签名 assistant turn。
- stream 只有在严格终态聚合通过后才保存；块停止后的 delta、缺失终态、重复 block、非法工具参数和大小超限都会失败。
- Anthropic 流式工具参数和非流式参数都规范化为 sorted-key JSON，避免合法空白/键顺序差异导致下一轮误拒绝；思考 signature 本身不做伪造的本地密码学验证。
- structured response 或 `outputConstraint` 与既有 continuation 冲突时，在 transport 前失败，不发送会被丢弃的请求。
- 私有思考不进入 `BoneInferenceAssistantTurn`、普通事件、日志、业务 Tool 参数或普通 Codable checkpoint。`reasoningDisclosure` 仅决定内存中可读结果是否向调用方交付。

这不是防篡改存储：Host 仍需把 continuation 当作敏感、不透明、可信存储对象，并在跨 Run 恢复时保留绑定字段。

## 官方依据与执行验证边界

实现依据和测试 fixture 使用了公开资料：

- OpenAI Chat Completions 的 `reasoning_effort` 和 `max_completion_tokens`；
- Anthropic extended thinking / tool workflow 的 budget、完整 thinking block 回传与工具循环；
- Gemini `ThinkingConfig` 的 `thinkingBudget`、`thinkingLevel` 和 `includeThoughts`；
- DeepSeek thinking mode 的 `thinking.type`、`reasoning_effort` 和 `reasoning_content`；
- 各厂商模型页对本地目录限制的逐渠道核验。

本地测试只验证请求映射、失败边界、响应形态、续接身份和合成 SSE；没有调用真实付费模型，不代表任意 Provider、兼容网关或模型 ID 已在线验收。上线前 Host 应使用无敏感数据完成自己的 Provider Smoke，并把确切端点/mapper 身份写入 profile。
