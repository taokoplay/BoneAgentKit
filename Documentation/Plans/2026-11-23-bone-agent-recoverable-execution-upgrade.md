# BoneAgentKit 可恢复 Agent 执行升级计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.


> **当前状态（2026-11-25）**
>
> SDK 的 Session 控制面、Store 合同、恢复协调器、Effect Receipt 恢复决策、Session/Step/Snapshot 绑定校验和定向测试已完成。WorkflowRunnerDemo 已接入进程内 Host 适配器、命令行恢复测试和 iOS 实验入口。真实数据库 Store、跨进程与重启验收、真实崩溃测试、快照加密、联合事务和性能基线仍未完成。iOS 新鲜构建本轮未通过环境验证，不能作为交付证据。
>
> 计划中的复选框记录原始实施过程。阅读当前能力时，以本状态摘要、Architecture.md、WorkflowAndRecovery.md 和 CharacterHostIntegration.md 的当前实现说明为准。

**Goal:** 在不复制 DSH 业务对象的前提下，把 BoneAgentKit 当前已有的 Tool Calling、Conversation、Workflow、Effect Receipt 和文件资源能力组合成可暂停、可恢复、可审计的 Agent 执行内核。

**Architecture:** 第一阶段新增一个薄的 Agent Execution Session 编排层，使用现有 `BoneAgentConversation` 保存模型上下文，使用 `BoneWorkflowAgentExecutionSnapshot` 保存私有快照引用，使用 `BoneWorkflowAgentStepCheckpoint`、`BoneWorkflowExecutionSession` 和 `BoneWorkflowWorkLedger` 保存执行控制面，使用 `BoneEffectIntent`/`BoneEffectReceipt` 处理副作用恢复。普通 `BoneAgent.run` 和现有 Tool Calling API 保持兼容，长期任务通过显式 Session/Work Item 入口启用持久化。

**Tech Stack:** Swift 6、Swift Package Manager、Foundation Codable、XCTest、现有 BoneAgentKit Workflow persistence contracts。

**当前状态（2026-11-24）：** SDK Session 控制面、恢复协调器、Effect Receipt 恢复入口、Session/Step/Snapshot 绑定校验和定向测试已完成。WorkflowRunnerDemo 已接入 Host 适配器、命令行测试和 iOS Demo UI。真实数据库 Store、跨进程与重启验收、真实崩溃测试、性能基线和完整的 Session/Step/Snapshot 单事务 Host 实现仍未完成。

**已完成：**

- Session 控制面、CAS、lease generation 和 Attention 状态。
- Conversation 私有 Snapshot 引用及 Session/Step/Snapshot 绑定校验。
- Coordinator 的恢复前校验、等待状态、已确认 Receipt 提交和未知副作用 fail-closed 处理。
- SDK 与 WorkflowRunnerDemo 定向测试，Demo 全量测试。
- Demo Host 适配器和 iOS Demo 的创建、等待用户、恢复续跑、Inspect 状态入口。

**仍未完成：**

- 生产数据库 Store、加密快照、联合事务和提交结果未知后的独立连接调和。
- 跨进程、重启、真实崩溃、快照篡改和真实外部副作用对账验收。
- 长文件 Session 的增量快照、历史 Snapshot 清理和性能基线。
- iOS Simulator 在当前机器上的新鲜构建和 UI 测试执行，本轮受 CoreSimulator 与用户缓存目录权限阻断。

---

## 设计结论

### 产品边界

BoneAgentKit 只增加 Agent Runtime 的长期执行能力，不引入 DSH 的 Ticket、项目、组织、报表或外部业务对象。SDK 负责执行状态、恢复合同、权限继承、工具调用历史和副作用对账。Host 负责数据库、加密、真实快照存储、用户 UI、外部业务实体查询和人工确认。

### 第一阶段必须闭合的恢复链路

```text
create session
→ persist admission and initial conversation snapshot
→ acquire run lease
→ execute one attempt
→ persist conversation snapshot and tool result boundary
→ persist effect intent / receipt
→ pause, wait, fail or finish
→ reload and validate identity, revision, lease and configuration
→ resume only when the previous boundary is known safe
```

中断发生在已发出副作用但 Receipt 未确认时，Session 必须进入 `recoveryRequired`。SDK 不根据“工具声明幂等”自动重放未知副作用。

### 不在第一阶段做的内容

- Subagent 调度
- 动态 DAG 和多步骤图编排
- 通用 Worker 池
- 自动模型切换
- 自动降级 Prompt 或工具权限
- 未经 Host 对账的未知副作用重试
- 将完整 Prompt、凭据、PDF 密码或 Tool 正文写入普通 Workflow checkpoint

---

## 文件结构与责任

### 新增文件

- `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSession.swift`
  - 定义长期 Agent Session 的公开身份、状态、恢复原因、Attention 状态、配置绑定和当前快照引用。
  - 只保存可验证的控制面事实，不承载完整私有消息正文。
- `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSessionStore.swift`
  - 定义 Session 的 open/load/commit/acquireLease/transition 合同。
  - 明确 CAS、lease generation 和未知提交结果的处理。
- `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSessionCoordinator.swift`
  - 组合 Conversation、Workflow Step、Execution Snapshot、Effect Planner 和 Session Store。
  - 负责 create、pause、wait、resume、markRecoveryRequired、complete 的顺序与边界。
- `Tests/BoneAgentKitTests/AgentExecutionSessionTests.swift`
  - 覆盖状态机、身份绑定、revision、lease、Attention 和序列化约束。
- `Tests/BoneAgentKitTests/AgentExecutionSessionCoordinatorTests.swift`
  - 覆盖成功恢复、快照缺失、配置漂移、未知副作用、重复提交和租约围栏。
- `Tests/BoneAgentTestingTests/AgentExecutionSessionContractSuiteTests.swift`
  - 将关键 Store 合同加入独立测试产品，供 Host Store 实现复用。

### 修改文件

- `Sources/BoneAgentKit/Workflow/Steps/BoneWorkflowAgentStep.swift`
  - 增加 Session 绑定的稳定引用字段或适配入口，保留旧初始化和旧 checkpoint 解码兼容。
- `Sources/BoneAgentKit/Workflow/Recovery/BoneWorkflowAgentExecutionSnapshot.swift`
  - 增加快照 schema、内容摘要和配置绑定校验所需的最小字段，旧 schema 仍可读取。
- `Sources/BoneAgentKit/Workflow/Recovery/BoneWorkflowRecoveryPlanner.swift`
  - 将未知副作用映射为统一的 Session recovery reason，继续 fail-closed。
- `Sources/BoneAgentKit/Agent/Conversation/BoneAgentConversation.swift`
  - 只在需要时增加公开的受控恢复元数据读取能力，不暴露私有消息正文给日志或事件。
- `Sources/BoneAgentKit/Agent/Core/BoneAgent.swift`
  - 增加从已认证 Snapshot 恢复 Conversation 的窄入口，复用现有 `restoreConversation` 校验。
- `Documentation/WorkflowAndRecovery.md`
  - 描述 Session、Attention、恢复边界和 Host Store 责任。
- `Documentation/Architecture.md`
  - 更新 Agent Runtime 层次和长期任务入口。
- `Documentation/CharacterHostIntegration.md`
  - 补充 Host 必须提供的 Session Store、Snapshot Store 和人工 Attention 处理。
- `Examples/WorkflowRunnerDemo/Sources/WorkflowRunnerDemo/DemoLiveWorkflow.swift`
  - 增加一个最小暂停/恢复演示，不改变现有 Demo 工具合同。
- `Examples/WorkflowRunnerDemo/Tests/WorkflowRunnerDemoTests/...`
  - 在 `LiveWorkflowTests.swift` 增加跨实例恢复、权限等待和恢复要求展示测试。

---

## 阶段 0：基线和兼容边界

### Task 0.1：锁定当前行为

**Files:**
- Test: `Tests/BoneAgentKitTests/ConversationContinuityTests.swift`
- Test: `Tests/BoneAgentKitTests/WorkflowStepControllerTests.swift`
- Test: `Tests/BoneAgentKitTests/WorkflowRecoveryTests.swift`
- Test: `Tests/BoneAgentKitTests/PersistenceContractTests.swift`

- [ ] 运行现有定向测试，记录基线。

```bash
swift test --filter ConversationContinuityTests
swift test --filter WorkflowStepControllerTests
swift test --filter WorkflowRecoveryTests
swift test --filter PersistenceContractTests
```

Expected: 当前基线测试通过，或把已有失败记录为与本次无关的基线缺口。

- [ ] 检查工作区差异，确保后续只触碰本计划列出的文件，不覆盖其他并行修改。

```bash
git diff --name-only
 git status --short
```

### Task 0.2：确认恢复数据分类

- [ ] 为新的 Session 控制面字段使用 `safeState` 或 `opaqueReference`。
- [ ] Conversation 私有状态继续由 `BoneWorkflowAgentExecutionSnapshotStore` 保存，不放入普通 checkpoint。
- [ ] Provider continuation 只能出现在 Host-owned 私有快照或受控加密存储。

验收标准：所有新增公共类型都能说明其数据分类和 Host 保存责任。

---

## 阶段 1：Session 控制面

### Task 1.1：先写 Session 状态和不变量测试

**Files:**
- Create: `Tests/BoneAgentKitTests/AgentExecutionSessionTests.swift`

- [ ] 覆盖以下行为。

```swift
func testNewSessionStartsActiveAtRevisionOne()
func testAttentionStatesRoundTripThroughCodable()
func testTerminalStateCannotResume()
func testRevisionConflictDoesNotMutateState()
func testLeaseGenerationMustAdvanceBeforeResume()
func testConfigurationBindingMismatchRequiresRecovery()
func testInvalidOpaqueReferenceAndDigestAreRejected()
```

- [ ] 先运行测试，确认新类型尚不存在导致编译失败。

### Task 1.2：实现 Session 控制面值类型

**Files:**
- Create: `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSession.swift`

- [ ] 定义以下稳定类型。

```swift
public enum BoneAgentExecutionSessionState: String, Codable, Sendable {
    case active
    case waitingForUser
    case waitingForAuthorization
    case waitingForReview
    case paused
    case running
    case failed
    case recoveryRequired
    case completed
    case cancelled
}

public enum BoneAgentExecutionAttention: Codable, Equatable, Sendable {
    case userInput(requestID: String)
    case authorization(ticketID: BoneAuthorizationTicketID)
    case review(reviewID: String)
    case externalEvent(eventID: String)
    case recovery(reason: BoneAgentExecutionRecoveryReason)
}

public enum BoneAgentExecutionRecoveryReason: String, Codable, Sendable {
    case missingSnapshot
    case snapshotBindingMismatch
    case providerContinuationInvalid
    case toolOutcomeUnknown
    case effectReceiptUnknown
    case leaseConflict
    case configurationDrift
    case persistenceOutcomeUnknown
}

public struct BoneAgentExecutionSession: Codable, Equatable, Sendable {
    public let sessionID: String
    public let runID: BoneRunID
    public let workflowIdentity: String
    public let workflowRevision: UInt64
    public let configurationDigest: String
    public let toolCatalogDigest: String
    public let promptProfileDigest: String?
    public let state: BoneAgentExecutionSessionState
    public let attention: BoneAgentExecutionAttention?
    public let snapshotReference: BoneWorkflowAgentExecutionSnapshotReference?
    public let revision: UInt64
    public let leaseGeneration: UInt64
}
```

- [ ] 为每个 initializer 和 transition 添加中文注释，说明用途、入参和返回值。
- [ ] 所有 ID、digest、revision、state transition 做严格校验。
- [ ] 不把 Message、Tool Result 或 Provider continuation 直接暴露到该控制面值类型。

- [x] 运行 Session 定向测试。

```bash
swift test --filter AgentExecutionSessionTests
```

Expected: PASS。

### Task 1.3：实现 Store 合同和内存参考实现

**Files:**
- Create: `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSessionStore.swift`
- Create: `Tests/BoneAgentTestingTests/AgentExecutionSessionContractSuiteTests.swift`

- [ ] 提供以下协议方法。

```swift
public protocol BoneAgentExecutionSessionStore: Sendable {
    func open(_ session: BoneAgentExecutionSession) async throws -> BoneAgentExecutionSession
    func load(sessionID: String) async throws -> BoneAgentExecutionSession
    func commit(
        _ session: BoneAgentExecutionSession,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentExecutionSession
    func acquireLease(
        sessionID: String,
        expectedRevision: UInt64
    ) async throws -> BoneAgentExecutionSession
}
```

- [ ] Store 对旧 revision、旧 lease、身份漂移和重复 open 做 fail-closed 处理。
- [ ] commit 结果未知时不自动 retry，调用方必须 load 后重建协调器。
- [ ] 用 `BoneInMemoryAgentExecutionSessionStore` 作为测试参考实现，文档明确它不能替代数据库崩溃测试。
- [ ] 运行独立合同测试。

```bash
swift test --filter AgentExecutionSessionContractSuiteTests
```

Expected: PASS。

---

## 阶段 2：恢复协调器

### Task 2.1：先写 Coordinator 恢复矩阵测试

**Files:**
- Create: `Tests/BoneAgentKitTests/AgentExecutionSessionCoordinatorTests.swift`

- [ ] 覆盖以下场景。

```swift
func testCreatePersistsAdmissionBeforeExecution()
func testSuccessfulTurnCommitsConversationSnapshotAndSessionTogether()
func testMissingSnapshotEntersRecoveryRequiredWithoutModelCall()
func testConfigurationDriftStopsBeforeModelCall()
func testWaitingForAuthorizationDoesNotConsumeToolAuthorization()
func testResumeUsesNewLeaseGeneration()
func testUnknownEffectOutcomeNeverReexecutesAutomatically()
func testKnownReceiptCanCommitWithoutReexecutingTool()
func testCommitFailureRequiresReloadBeforeFurtherWrites()
func testConcurrentResumeAllowsOnlyOneLeaseOwner()
```

- [ ] 为模型调用和 Tool Handler 使用计数器，证明恢复失败路径没有偷偷发起第二次推理或副作用。

### Task 2.2：实现恢复协调器

**Files:**
- Create: `Sources/BoneAgentKit/Workflow/Execution/BoneAgentExecutionSessionCoordinator.swift`
- Modify: `Sources/BoneAgentKit/Agent/Core/BoneAgent.swift`
- Modify: `Sources/BoneAgentKit/Agent/Conversation/BoneAgentConversation.swift`

- [x] Coordinator 只负责控制面顺序。
- [x] 从 Snapshot Store 读取并调用现有 `BoneAgent.restoreConversation(privateState:modelID:bindingID:expectedID:expectedRevision:)`。
- [x] 恢复前重新验证 workflow revision、configuration digest、tool catalog digest、prompt profile digest 和 lease generation。
- [x] `missingSnapshot`、`configurationDrift`、`providerContinuationInvalid` 等情况在模型调用前进入 `recoveryRequired`。
- [x] 等待用户、授权、审核和外部事件通过 Attention 记录，不用异常字符串表达状态。
- [x] 只在前置事实已确认时调用 `BoneAgentConversation.send`。
- [x] 每次成功 Turn 后保存新的私有快照引用，再提交 Session revision。
- [x] 发生副作用时先沿用现有 `BoneEffectIntent`，Receipt 未确认时调用 `BoneWorkflowRecoveryPlanner`，禁止自动重放未知效果。
- [x] 对 Host Store 返回未知结果的情况设置 `persistenceOutcomeUnknown`，不得继续写后继 revision。

- [x] 运行定向测试。

```bash
swift test --filter AgentExecutionSessionCoordinatorTests
```

Expected: PASS。

---

## 阶段 3：Workflow 和 Demo 接入

### Task 3.1：绑定现有 Agent Step

**Files:**
- Modify: `Sources/BoneAgentKit/Workflow/Steps/BoneWorkflowAgentStep.swift`
- Modify: `Sources/BoneAgentKit/Workflow/Recovery/BoneWorkflowAgentExecutionSnapshot.swift`
- Modify: `Tests/BoneAgentKitTests/WorkflowStepControllerTests.swift`
- Modify: `Tests/BoneAgentKitTests/WorkflowRunIntegrationTests.swift`

- [x] Session、Step checkpoint 和私有 Snapshot 的绑定校验已提供独立 SDK 合同。
- [x] 旧 Workflow 和缺少 Session scope 的 Effect 继续保持兼容读取路径。
- [x] 无法验证配置绑定、快照绑定或 lease 时进入 recoveryRequired 或明确冲突错误。
- [ ] 真实崩溃边界测试仍待 Host 数据库和跨进程环境完成。

```swift
func testCrashAfterConversationSnapshotBeforeStepCommitRequiresReload()
func testCrashAfterEffectIntentBeforeReceiptDoesNotReplayEffect()
func testOldCheckpointRemainsReadableButCannotClaimLongTermResume()
```

### Task 3.2：Demo 增加最小恢复演示

**Files:**
- Modify: `Examples/WorkflowRunnerDemo/Sources/WorkflowRunnerDemo/DemoLiveWorkflow.swift`
- Modify: `Examples/WorkflowRunnerDemo/Sources/WorkflowRunnerDemo/DemoWorkflowRunner.swift`
- Test: `Examples/WorkflowRunnerDemo/Tests/WorkflowRunnerDemoTests/LiveWorkflowTests.swift`

- [ ] 增加一个只读长任务示例，流程为文件分页读取、等待用户确认、继续读取、结束。
- [ ] 增加一个授权等待示例，展示 `waitingForAuthorization` 和 `resumeAfterAuthorization`。
- [x] Demo 已接入进程内可恢复 Session 创建、等待用户、恢复发送、状态检查和并发门禁测试。
- [x] Demo 只展示 SDK 状态和事件，不新增生产 Tool ID。
- [x] Demo 展示 `recoveryRequired` 的稳定错误类别，真实数据库恢复入口仍待 Host 实现。

---

## 阶段 4：持久化和跨进程验收

### Task 4.1：补 Host Store 验收接口

**Files:**
- Modify: `Documentation/CharacterHostIntegration.md`
- Modify: `Documentation/WorkflowAndRecovery.md`
- Modify: `Documentation/Architecture.md`

- [x] 记录 Host Store 最低要求。

```text
必须支持
- 原子 CAS
- revision 和 lease generation 围栏
- 快照加密和认证
- session、step、snapshot 的联合提交或可验证调和
- commit 结果未知后的重读
- 过期快照清理
- 敏感数据分类
```

- [x] 明确 SDK 内存 Store 只用于测试。
- [x] 明确长文件结果应通过文件资源的 opaque reference 和 version 保存，不把大正文塞入 Session JSON。

### Task 4.2：跨进程和崩溃测试

**Files:**
- Create or modify: `Tests/BoneAgentTestingTests/`
- Modify: `Examples/WorkflowRunnerDemo/Tests/`

- [ ] 覆盖进程退出、重启、删除原始文件、快照篡改、旧 lease 写入、重复恢复和未知 Receipt。
- [ ] 验收以下不变量。

```text
同一个 effect identity 最多一次被自动执行
未知副作用绝不自动重放
旧 lease 不能提交新状态
配置漂移不自动扩权
快照缺失不发起模型请求
大文件正文不进入普通 checkpoint
```

### Task 4.3：性能基线

- [ ] 用真实磁盘文件测量 Session snapshot、长消息增量保存和恢复读取。
- [ ] 确认短期 `BoneAgent.run` 不增加强制持久化开销。
- [ ] 确认长期 Session 采用增量日志或内容寻址引用，不复制完整大文件正文。
- [ ] 记录内存峰值、快照大小、恢复耗时和 Tool 调用额外延迟。

---

## 阶段 5：后续能力

阶段 1-4 通过后，再单独立项实现：

- 受限 Subagent
- Assignment / Worker Lease
- 并发预算和子任务调度
- 统一 Attention 恢复 UI
- Session 事件查询和审计导出
- 外部事件触发的恢复

Subagent 必须继承父 Session 的 Tool 白名单、Impact Policy、授权范围、资源 Scope 和预算。没有这些前置约束时，不实现 Subagent。

---

## 兼容策略

- 普通 `BoneAgent.run`、`makeConversation`、现有 Tool Definition 和 Provider wire 不改语义。
- 现有 `BoneAgentConversation` schemaVersion 1 保持可读。
- 新长期 Session 使用独立 schemaVersion 1，不把字段硬塞进 Conversation 私有 JSON。
- 旧 Workflow checkpoint 可读取，但缺少长期 Session 绑定时只能进入受限恢复检查，不能隐式继续执行。
- 新增 API 采用独立文件和新增入口，避免改写现有 Store 方法签名。
- Host 不提供新 Store 时，现有短期运行继续工作，长期恢复能力明确返回缺少持久化能力。

## 关联模块和性能影响

- Agent Loop：复用现有消息和 continuation，不改变 Tool 调度顺序。
- Workflow：增加 Session reference 和 Attention 状态，会增加每个长期任务的一次小型 CAS 提交。
- 文件资源：只保存资源引用、版本和游标，避免复制 PDF、Office、OCR 或二进制正文。
- Provider：恢复时需要重新校验 continuation 和模型绑定，可能因 Provider 版本变化进入恢复要求。
- Demo：增加状态展示和恢复入口，不改变已有工具数量和工具 Schema。
- 性能：普通短 Run 无额外持久化，长期 Session 增加控制面写入和快照索引开销。大结果继续使用已有资源快照和 opaque reference。

## 验收门槛

升级完成前必须满足：

1. Session 状态、CAS、lease 和 Attention 定向测试通过。
2. 成功 Turn 可以跨实例恢复并继续下一轮。
3. 快照缺失、配置漂移、Provider continuation 无效时不会调用模型。
4. Effect Intent 已开始但 Receipt 未确认时不会自动重放。
5. 旧 API 和旧 Conversation 状态仍可读取。
6. WorkflowRunnerDemo 能展示暂停、授权等待、恢复和 recoveryRequired。
7. 定向测试、SwiftPM 全量测试、Demo 测试和可用的 iOS 构建均完成验证。
8. 文档解释 Host Store、加密、CAS、快照、性能和失败边界。
