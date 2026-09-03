<div align="center">

# BoneAgentKit

**面向 Swift 应用的可控 Agent Runtime。**

统一模型推理、Tool Calling、Workflow、授权、持久化与失败恢复。

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9%2B-F05138?logo=swift&logoColor=white)](https://www.swift.org)
[![iOS 13+](https://img.shields.io/badge/iOS-13%2B-111111?logo=apple)](https://developer.apple.com/ios/)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-111111?logo=apple)](https://developer.apple.com/macos/)
[![License: AGPL-3.0-only](https://img.shields.io/badge/License-AGPL--3.0--only-663399)](LICENSE)

</div>

BoneAgentKit 在基础模型之上提供确定、可审计、可恢复的执行环境。它不绑定聊天 UI、业务数据库或 Prompt 内容仓库；App Host 保留业务领域、用户体验和持久化实现。

## Products

| Product | 用途 | 二进制依赖 |
| --- | --- | --- |
| `BoneAgentKit` | 推理、Tool Calling、Agent Runtime、Workflow、授权和恢复契约 | 无 |
| `BoneAgentTesting` | Synthetic Provider、Scripted Engine、Recorder、Scenario 和 Crash Harness | 无，仅测试使用 |
| `BoneAgentLocalRuntime` | 本地模型 Catalog、下载、校验、存储、环境规划和 Runtime Probe | 无 |
| `BoneAgentLlama` | llama Runtime seam、Prompt、Probe 与默认 text-only、可显式扩展 Tool Calling 的 Inference Engine | 无，不包含 llama.cpp |

Provider 渠道图片由 `BoneAgentKit` 内部资源 Target 管理，不作为独立 Product 暴露。

## 安装

在 `Package.swift` 中精确固定已审核版本：

```swift
dependencies: [
    .package(
        url: "https://github.com/taokoplay/BoneAgentKit.git",
        exact: "0.2.0-alpha.7"
    )
]
```

基础运行目标：

```swift
.target(
    name: "AppCore",
    dependencies: [
        .product(name: "BoneAgentKit", package: "BoneAgentKit")
    ]
)
```

测试目标可按需增加：

```swift
.product(name: "BoneAgentTesting", package: "BoneAgentKit")
```

本地模型能力是独立 Product，只有显式依赖时才会进入调用方的依赖图。

> [!IMPORTANT]
> 当前为预发布版本。生产项目应精确固定版本或 revision，不要自动跟随 `main`。

## 五分钟开始

```swift
import BoneAgentKit

let registry = try BoneAgentToolRegistry(
    tools: [BoneAnyAgentTool(EchoTool())]
)

let agent = BoneAgentKit(
    inferenceEngine: engine,
    toolRegistry: registry,
    toolContext: BoneAgentEmptyContext(),
    configuration: try BoneAgentConfiguration(maximumSteps: 4)
)

let result = try await agent.run(
    modelID: "model-id",
    messages: [
        BoneInferenceMessage(role: .user, content: "Say hello")
    ]
)
```

完整的 Engine 与 Tool 定义见 [5 分钟快速开始](Documentation/GettingStarted.md)。

## 核心能力

### 推理与 Tool Calling

- 供应商无关的文本、Streaming、Tool Calling 与结构化输出契约；
- 云端与本地目录共用带证据来源的可选模型能力 Profile，已知能力与 Engine/Runtime 实现取交集，unknown 保持兼容且不冒充模型级验证；
- OpenAI、Anthropic、Gemini 请求和事件聚合，并为经过真实 Smoke 绑定身份的精确模型提供原生 Output Constraint seam；
- 请求级 Capability 推导与 Output Constraint：云端使用官方 JSON Schema 字段，本地使用受信任 Runtime Constraint；未实现、未验证或身份漂移时在联网或本地生成前 fail closed；
- 强类型、`Codable & Sendable` 的 Tool Schema 和结果模型；
- 默认串行、显式只读并行的确定性调度。

### Workflow 与恢复

- 冻结 Workflow Plan 和 Run / Step / Attempt 状态机；
- 原子 Run + Checkpoint、CAS 和 lease generation fencing；
- Effect Intent / Receipt 与 reconcile-first 恢复；
- 对不可确认副作用使用 `outcomeUnknown / recoveryRequired`，不伪造 exactly-once；
- 安全事件、状态投影和可注入 Persistence seam。

### 本地模型基础设施

- 版本化 Catalog、可信下载源、SHA-256 和原子安装；
- 设备环境快照、确定性运行预算和两阶段 Probe；
- 不链接 llama.cpp 的 Runtime seam、真实 Token 容量规划、模板无关 Conversation 与 GGUF Native Template Renderer seam；
- Tool Envelope 与会话模板解耦，并提供受约束的严格 JSON Tool Envelope；
- 当前状态快照与 `AsyncStream` 实时通知。

## 执行模型

```text
User Intent
    ↓
Agent Runtime / Context Planning
    ↓
Model Inference
    ↓
Tool Scheduling / Authorization
    ↓
Tool Execution / Effect Receipt
    ↓
Persistence / Recovery
    ↓
Next Step or Final Result
```

Kit 负责执行控制面；App Host 负责业务 Intent、数据来源、UI、用户设置、凭据注入和持久化实现。两者只通过公开协议、类型化 Adapter 和不透明引用连接。

详见 [架构与模块边界](Documentation/Architecture.md) 和 [App Host 集成边界](Documentation/CharacterHostIntegration.md)。

## 文档

### 开始使用

- [5 分钟快速开始](Documentation/GettingStarted.md)
- [Swift Package 接入](Documentation/PackageIntegration.md)
- [Provider 与 Tool 扩展](Documentation/ProviderIntegration.md)

### 核心概念

- [架构与模块边界](Documentation/Architecture.md)
- [Tool Calling](Documentation/ToolCalling.md)
- [Workflow 与恢复](Documentation/WorkflowAndRecovery.md)
- [本地模型基础设施](Documentation/LocalModels.md)

### 运行与治理

- [Testing 与 Harness](Documentation/Testing.md)
- [安全与隐私](Documentation/SecurityAndPrivacy.md)
- [来源与许可](Documentation/LicensingAndProvenance.md)
- [完整文档地图](Documentation/INDEX.md)

## 验证

```bash
swift package resolve
swift test
swift test \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
swift run BoneAgentLiveProviderSmoke --dry-run
```

## 当前限制

- 当前提供确定性 Workflow + 局部 Agent Step，不支持任意 DAG；
- 不保证 exactly-once；不可查询的外部副作用可能需要人工恢复；
- App 被系统终止后不会永久后台运行，下次启动通过新 lease 恢复；
- Synthetic Fixture 和 Simulator 不能替代真机及真实 Provider 验收；
- `BoneAgentLlama` 默认只承诺文本能力；Native Template、受约束输出和 Tool Calling 都需具体 Runtime 显式实现并通过绑定完整执行身份的真实 Smoke，暂不提供 Token Streaming 或可靠加载百分比；
- 未核验的 Model 级能力保持 unknown，不按模型名称猜测；当前 bundled 云模型尚未写入 Provider Smoke 身份，因此云端 Constraint seam 默认不自动启用。

## 许可证

从 `0.2.0-alpha.2` 起，源码和文档采用 [GNU AGPL v3.0 only](LICENSE)（`AGPL-3.0-only`）。`0.2.0-alpha.1` 及更早 tag 保持签发时的 proprietary 许可。

> [!NOTE]
> `Sources/BoneAgentProviderAssets/Resources/ProviderIcons/` 下的 Provider PNG 及其中涉及的第三方商标不在 AGPL 授权范围内。分发前请阅读 [NOTICE.md](NOTICE.md)。
