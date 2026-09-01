# Local Runtime Probe Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在 `BoneAgentLocalRuntime` 中实现静态 Artifact inspection、Adapter 兼容性契约和两阶段 Runtime Probe 编排。

**Architecture:** Core 仅验证 Store、GGUF magic、Adapter descriptor、runtime version、设备与 plan；真实 load/smoke 由注入 Adapter Probe 完成。所有结果归一为不泄露路径、Prompt 或底层错误文本的确定性 Report。

**Tech Stack:** Swift 5.9、Foundation、CryptoKit（经 Store）、Swift Concurrency、XCTest、Swift 6 strict concurrency。

---

### Task 1: Probe report and adapter contracts

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Probe/BoneLocalRuntimeProbeModels.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalRuntimeProbeModelsTests.swift`

**Steps:**
1. 编写失败测试，覆盖 depth、adapter descriptor 校验、check 严重度和 report 总体状态。
2. 运行 `swift test --filter BoneLocalRuntimeProbeModelsTests`，确认类型缺失 RED。
3. 最小实现 Sendable/Equatable 公共契约和 fail-closed 聚合。
4. 重跑定向测试，确认 GREEN。

### Task 2: Static artifact inspector

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Probe/BoneLocalModelArtifactInspector.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalModelArtifactInspectorTests.swift`

**Steps:**
1. 写失败测试：合法 GGUF magic、错误 magic、短文件、未安装、可选 checksum 状态。
2. 运行定向测试确认 RED。
3. 实现 bounded four-byte read 和 Store 状态映射；不解析完整 GGUF。
4. 重跑确认 GREEN。

### Task 3: Two-stage probe coordinator

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Probe/BoneLocalRuntimeProbeCoordinator.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalRuntimeProbeCoordinatorTests.swift`

**Steps:**
1. 写 fixture Adapter Probe 与失败测试：metadata 不调用 Adapter、load 调用一次、format/version/memory/depth fail closed。
2. 运行定向测试确认 RED。
3. 实现静态检查、Planner、Adapter 调用和确定性 checks 排序。
4. 重跑确认 GREEN。
5. 增加 temporary unavailable/incompatible/unknown failure 映射测试并确认 RED→GREEN。

### Task 4: Documentation

**Files:**
- Modify: `Documentation/LocalModels.md`
- Modify: `README.md`
- Modify: `API_BASELINE.md`
- Modify: `CHANGELOG.md`

**Steps:**
1. 说明 metadata/load/smoke、Adapter seam、隐私边界和非目标。
2. 更新公开类型索引和示例。
3. 运行 `git diff --check`。

### Task 5: Verification and local commits

**Steps:**
1. 运行 LocalRuntime 定向测试。
2. 运行 `swift test`。
3. 运行 strict concurrency + warnings-as-errors。
4. 运行 Package graph、diff 和敏感模式扫描。
5. 按设计、contracts/inspector、coordinator、docs 拆分本地 commit。
6. 确认不 push/tag/merge，且任何 App Host 均未被修改。
