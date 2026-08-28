# BoneAgentKit 架构

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

ParsingBook 的 Catalog、模型发现、Provider 连通性、生图和普通文本执行已完整使用这条链路；角色业务复用 `AIChatSource`，因此同步使用 BoneInference 文本 Engine。设置 UI、数据库与用户配置保留在 App Host，但只映射到 BoneInference 公开类型。生产源码、Xcode 引用和旧 Package 均已清零；`Frameworks/BoneAgentKit` 是唯一 Bone Agent Kit Package。

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

`text`、`structuredOutput`、`toolCalling`、`streaming` 当前都是 MVP 契约中的 Provider **声明性 metadata**。`BoneAgent` Runtime 目前不据此门禁：它直接调用 `infer`，再按实际返回的 `.finish`、`.structured` 或 `.toolCall` 分支运行；调用方不能把 metadata 误解为运行时强制校验。

图片生成例外：最终 `capabilities` 会从 `nonImageCapabilities` 移除 `.imageGeneration`，仅当 `imageGenerator` 非 `nil` 时加入；`generateImages` 是统一入口强制执行组件存在性与响应资源复验。

| 能力 | Capability 状态 | 当前执行事实 |
| --- | --- | --- |
| 文本推理 | MVP 声明性 metadata | Runtime 可消费 `.finish`，但目前不检查 `.text` 声明 |
| 结构化输出 | MVP 声明性 metadata | Runtime 可消费 `.structured`，但目前不检查 `.structuredOutput` 声明 |
| Tool Calling | Provider 声明性 metadata | Runtime 可消费完整 Assistant Turn 和 0...N Tool Calls；Provider 模型是否真实支持仍由目录与真机 Smoke 验收 |
| Streaming | Provider 可选完整结果能力 | `BoneInferenceStreaming` 复用通用 Request/Response，只在协议完整终态后交付；Agent Runtime 仍没有 token 增量 API，也不按 capability metadata 门禁 |
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
