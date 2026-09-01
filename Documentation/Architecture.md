# BoneAgentKit 架构

## Agent Harness 架构定位

BoneAgentKit 是采用 **Agent Harness 架构**的生产级 Swift Agent Runtime SDK。这里的 Agent Harness 指围绕基础模型建立的受控执行环境，而不是某个名为 `Harness` 的类或目录。它将一次 Agent Run 所需的模型适配、上下文规划、Agent Loop、Tool 调度、策略与授权、状态提交、副作用对账和失败恢复组织成同一套控制面。

```text
User Intent
→ Agent Runtime / Agent Loop
→ Context Window Planning
→ Model Inference
→ Tool Scheduling / Authorization
→ Tool Execution / Effect Receipt
→ Persistence / Recovery
→ Next Agent Step or Final Result
```

| Agent Harness 职责 | BoneAgentKit 实现 |
| --- | --- |
| Model / Provider abstraction | `Inference/Core`、`Inference/Providers` |
| Transport 与端点安全 | `Inference/Transport` |
| Model Catalog 与能力发现 | `Inference/Catalog`、`Inference/Discovery` |
| Context Window 管理 | `Inference/Context` |
| Agent Loop 与运行配置 | `Agent/Core` |
| Tool Registry 与强类型 Context | `Agent/Tools` |
| Tool Schema、策略与调度 | `Agent/Schema`、`Agent/Policies`、`Agent/Scheduling` |
| Run 事件 | `Agent/Events` |
| 授权和稳定 Tool Call 身份 | `Workflow/Authorization` |
| Tool 执行和副作用控制 | `Workflow/Execution`、`Workflow/Effects` |
| Checkpoint、持久化和恢复 | `Workflow/Persistence`、`Workflow/Recovery` |
| 可恢复步骤 | `Workflow/Steps` |
| Synthetic Test Harness | 独立 Product `BoneAgentTesting` |

因此，BoneAgentKit **保留 Agent Harness 的架构能力，但不再用 Harness 作为生产 SDK 的品牌或领域目录**。`BoneAgentKit` 表示生产运行时；`BoneAgentTesting` 表示测试支持；只有 `BoneCrashTestHarness` 这类真实测试支架继续使用 Harness 术语。旧 `BoneHarnessAgentKit` 仅作为 deprecated Swift typealias 提供源码迁移窗口，不代表当前架构分层。

## 分层与命名

BoneAgentKit 当前以仓库内独立 Swift Package 交付，依赖方向为 `ParsingBook → BoneAgentKit`，Kit 不反向引用 App 模型、数据库或 UI。

- `BoneInference*`：供应商无关的推理请求、响应、Provider 与 Transport 契约。
- `BoneAgent*`：Agent Runtime、Tool、Context、Registry、事件与确定性调度。
- `BoneWorkflow*` / `BoneEffect*`：持久 Workflow、授权、副作用与恢复契约。
- `BoneAgentTesting`：独立测试 Product，承载 Synthetic Fixture、Scripted Engine、Recorder、Scenario、Assertions、Crash Test Harness 与安全报告；生产 Product 不依赖它。

项目通过小协议和强类型 Context 做**协议组合**，不采用 `BaseAgent`，也不建立大型继承树。业务 Service 可由 UI、Tool 或测试直接调用，不能反向依赖 Agent Runtime。

## Provider 基础设施与退役终态边界

```text
ParsingBook Provider/目录模型
→ App Host 显式映射
→ BoneInferenceProviderConfiguration
→ BoneInference Provider
→ BoneInferenceHTTPTransport
→ BoneInferenceURLSessionTransport
```

`BoneInferenceHTTPTransport` 统一承载非流式 HTTP、模型发现有限重试和 SSE 事件请求。最终 URL 解析后执行 HTTPS/私网 HTTP 门禁，自定义 Header 不能覆盖认证、Cookie、Host 或消息边界字段；Transport 的错误和指标不携带 Prompt、正文、凭据、响应正文或 URL query。

ParsingBook 的 Catalog、模型发现、Provider 连通性、生图和普通文本执行已完整使用这条链路；角色业务复用 `AIChatSource`，因此同步使用 BoneInference 文本 Engine。设置 UI、数据库与用户配置保留在 App Host，但只映射到 BoneInference 公开类型。生产执行链不再依赖迁移前的 `AIProviderKit`；生产源码、Xcode 引用和旧 Package 均已清零，`Frameworks/BoneAgentKit` 是唯一 Bone Agent Kit Package。

旧 Kit 删除前的 `111 tests, 0 failures` 历史基线按行为类别接管，不复制旧源码或旧 API。完整映射与删除门禁见 [LegacyProviderMigration.md](LegacyProviderMigration.md)。

## 当前运行链路

```text
BoneAgentKit.run / runWorkflowStep
→ BoneAgent（actor，单 Run）
→ BoneInferenceEngine.infer
→ 完整 Assistant Turn（text / structured / 0...N Tool Calls）
→ BoneToolCallScheduler（默认串行，显式安全时有界并行）
→ BoneAgentToolRegistry
→ inference / Tool result checkpoint
→ persistence commit
→ 安全事件
```

Workflow 使用冻结 Plan、Run/Step/Attempt 状态机、组合 Persistence、CAS revision 与 lease generation fencing。副作用通过 Effect Intent / Effect Receipt 和 Recovery Planner 对账。每次 `infer` 消耗一步；Tool 参数和结果有容量门禁。

## Capability 与实现事实

`text`、`structuredOutput`、`toolCalling`、`streaming` 已从声明性 metadata 升级为 **Engine / Provider 级联网前运行时契约**。`BoneInferenceRequirements` 从 `BoneInferenceRequest` 自动推导需求，`BoneInferenceCapabilityValidator` 在 Provider Transport 前校验；`BoneAgent` 还会在发布 `runStarted` 前预检 Text 与 Tool Calling。明确不支持的请求不会发送 Prompt、执行 Tool 或产生 Provider 调用。

结构化输出采用显式协商：`requireNative` 必须具备原生 `.structuredOutput`；`nativeOrToolCall` 在原生能力不可用但 `.toolCalling` 可用时允许内部强制 Tool fallback。两种能力都不可用时联网前失败。Streaming 调用额外强制 `.streaming`，不静默退化为非流式。

图片生成继续由实现推导：最终 `capabilities` 会从 `nonImageCapabilities` 移除 `.imageGeneration`，仅当 `imageGenerator` 非 `nil` 时加入；`generateImages` 是统一入口强制执行组件存在性与响应资源复验。

第一阶段不按 Model ID 猜测能力：Catalog 或 Host 尚未提供可核验的模型级 Tool/Structured/Streaming 能力时保持 unknown。当前门禁只拒绝 Engine / Provider 已明确不支持的请求；后续再引入带来源的模型级能力交集。

| 能力 | Capability 状态 | 当前执行事实 |
| --- | --- | --- |
| 文本推理 | Engine 级强制 | `infer` 和 Agent Run 均要求 `.text`；缺失时联网和 `runStarted` 前失败 |
| 结构化输出 | Engine 级强制 + 显式 fallback | 原生输出要求 `.structuredOutput`；允许时可使用 `.toolCalling` fallback，结果仍需 JSON/Schema 验证 |
| Tool Calling | Engine 级强制 | 请求含 Tools 或 Agent Registry 非空时要求 `.toolCalling`；具体 Model 是否支持仍由目录与真机 Smoke 验收 |
| Streaming | Engine 级强制 | `streamInference` 额外要求 `.streaming`；只在协议完整终态后交付，不静默退化为非流式 |
| 图片生成 | 由实现推导 | `.imageGeneration` 只由 `imageGenerator` 推导，且由 `generateImages` 统一入口强制 |
| 图片编辑 | 后续 | 当前没有 Capability、请求 DTO 或 Runtime API，不得假设已实现 |

Capability metadata 不替代 Provider 自身的模型目录、鉴权、额度和参数校验。

## 事件与事实源

当前事件只有 `runStarted → toolCallStarted → toolCallFinished → runFinished` 四阶段。它们用于单次 Run 的观察，不是持久事实源；数据库状态、用户确认票据和恢复依据仍由 App 管理。

## Developer Experience Targets

| 使用动作 | 目标 |
| --- | --- |
| 看懂 Quick Start | 10 分钟 |
| 新项目完成接入 | 15 分钟 |
| 写出第一个 Tool | 30 分钟 |
| 建立第一个 Fixture 回归 | 1 小时 |
| 定位一次 Tool 调用失败 | 10 分钟以内 |

若公共抽象尚无第二真实调用方，应先留在项目 Adapter 层。退出框架应只需删除 Adapter，业务 Service 不受影响。
