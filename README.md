# BoneAgentKit

BoneAgentKit 是可供多个 Swift 项目复用的生产级 Swift Agent Runtime SDK。当前以私有 Swift Package 形式维护；最低工具链为 Swift 5.9，最低平台为 iOS 13 和 macOS 13，稳定版本遵循 SemVer。它采用当前 AI Agent 领域常说的 **Agent Harness 架构**：在基础模型之上提供可控执行环境，统一管理上下文、Agent Loop、Tool 调用、策略与授权、持久工作流、副作用和失败恢复。

`Harness` 在这里描述的是架构模式，不是生产 Module 或一级目录名称。生产代码按职责拆分为 `Agent + Inference + Workflow`，测试支架单独放在 `BoneAgentTesting`，避免把生产运行时与 Test Harness 混为一谈。早期 Task 1–3 的最小 Runtime 已扩展为完整 Tool Calling、Workflow 与 Testing 边界。对外提供两个 Library Product：

- `BoneAgentKit`：生产推理、Tool Calling、Agent Runtime、Workflow、授权、Persistence、副作用恢复契约与内置 Provider 渠道图片；
- `BoneAgentTesting`：仅测试调用方使用的 Synthetic Provider、Scripted Engine、Recorder、Scenario、Assertions、Crash Harness 与 Safe Report；
- `BoneAgentLocalRuntime`：本地模型 Catalog、Artifact、安全下载与断点恢复、安装校验、环境快照及确定性运行规划，不绑定 llama.cpp 或 Foundation Models。

渠道 PNG 由内部资源 Target 管理，调用方不需要了解或导入该实现模块。

生产 Product 不依赖 `BoneAgentTesting`。ParsingBook 的正文、角色 Parser、Evidence Grounder、数据库坐标、GRDB、手工字段保护和业务 Task DB 保留在 App Host。

## 框架定位

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

这条受控执行链构成 BoneAgentKit 的 Agent Harness。它不是聊天 UI、业务数据库或 Prompt 内容仓库；ParsingBook 等 App Host 负责业务 Intent、数据源、用户设置、UI 和数据库映射，Kit 负责供应商无关的模型执行与 Agent 控制面。完整组件映射见[架构与模块边界](Documentation/Architecture.md#agent-harness-架构定位)。

所有远程 Provider 共用 `BoneInferenceHTTPTransport` 作为联网 seam；具体 URLSession adapter 只负责发送已构造的请求并返回受限响应，不读取 App 全局状态，也不记录 Prompt、正文、Tool 参数/结果或凭据。迁移后的生产执行链不依赖 `AIProviderKit`，旧模块只作为迁移背景出现在边界文档中。

## 能力概览

- OpenAI、Anthropic、Gemini 非流式 Tool Calling 与严格 Streaming 聚合；
- 从请求字段自动推导 Text、Tool Calling、Streaming 与结构化输出需求，并在联网前强制校验 Engine 能力；
- ordered Assistant Turn、0...N Tool Calls、Provider-scoped continuation；
- 默认串行、显式只读 parallel-safe 的确定性多 Tool 调度；
- 强类型 Tool Schema、六维影响、预算与 fail-closed Authorization Grant；
- 冻结 Workflow Plan、Run/Step/Attempt 状态机、组合 Persistence、CAS 与 lease generation fencing；
- Effect Intent / Effect Receipt、reconcile-first 与 `outcomeUnknown` 恢复决策；
- 可恢复 Agent Workflow Step 和提交后事件；
- 独立 `MinimalWorkflowHost` 跨项目编译运行示例；
- ParsingBook `CharacterAgentHost` 不透明引用、业务 Bridge、灰度路由、任务中心投影和 Live Smoke 边界。

## 文档导航

1. [本地模型基础 Module](Documentation/LocalModels.md)
2. [快速开始](Documentation/GettingStarted.md)
3. [架构与模块边界](Documentation/Architecture.md)
4. [Tool Calling](Documentation/ToolCalling.md)
4. [Workflow 与恢复](Documentation/WorkflowAndRecovery.md)
5. [Testing](Documentation/Testing.md)
6. [安全与隐私](Documentation/SecurityAndPrivacy.md)
7. [Package 接入](Documentation/PackageIntegration.md)
8. [Character Host 接入](Documentation/CharacterHostIntegration.md)
9. [Provider 接入与扩展](Documentation/ProviderIntegration.md)
10. [来源与许可](Documentation/LicensingAndProvenance.md)

## 明确限制

- 不支持任意 DAG；当前是确定性 Workflow + 局部 Agent Step。
- 不保证 exactly-once；不可查询的外部副作用可能进入 `outcomeUnknown / recoveryRequired`。
- App 被系统终止后不会自动后台永久运行；下次启动通过新 lease 恢复。
- 自动 Contract、Synthetic Fixture 和 Simulator build 不能替代真机真实 Provider 验收。
- OpenAI、Anthropic、Gemini 的真实 Tool Calling Smoke 仍需 App 沙箱凭据、支持 Tool Calling 的模型以及用户明确确认联网和费用。
- Provider continuation、Prompt、正文、Tool 参数/结果和原始响应不得进入普通日志、事件或 Safe Report。
- 第一阶段 Capability 门禁强制 Engine / Provider 已知能力；Catalog 中未核验的 Model 级能力保持 unknown，不按模型名猜测。

## 快速接入

在其他 Swift Package 中使用远程私有仓库时，初期建议锁定精确预发布版本：

```swift
dependencies: [
    .package(
        url: "git@github.com:taokoplay/BoneAgentKit.git",
        exact: "0.1.0-alpha.1"
    )
]
```

目标依赖：

```swift
.product(name: "BoneAgentKit", package: "BoneAgentKit")
```

测试目标可额外依赖：

```swift
.product(name: "BoneAgentTesting", package: "BoneAgentKit")
```

Provider 渠道图片已经包含在 `BoneAgentKit` Product 中。调用方只需 `import BoneAgentKit`，按 Catalog 的稳定 `iconID` 读取对应显示倍率的 PNG：

```swift
let data = try catalog.iconData(
    iconID: entry.iconID,
    scale: 3
)
```

## 快速验证

```bash
swift package resolve
swift test
swift test \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift run BoneAgentLiveProviderSmoke --dry-run
```
