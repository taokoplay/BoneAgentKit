# BoneAgentLocalRuntime Foundation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 BoneAgentKit 增加无 llama.cpp/Foundation Models 二进制依赖的本地模型 Catalog、资产存储、完整性校验、环境快照与运行规划基础 Module。

**Architecture:** 新增公开 Product `BoneAgentLocalRuntime`，依赖 `BoneAgentKit` 以复用 `BoneModelContextLimits`，但不依赖任何具体 Runtime。模型事实、下载 Artifact、安装不变量和环境事实集中在该 Module；实际推理由后续 `BoneAgentLlama`、`BoneAgentFoundationModels` Adapter 实现。

**Tech Stack:** Swift 5.9、Foundation、CryptoKit、SwiftPM、XCTest、Swift 6 strict concurrency。

---

### Task 1: Local Model Catalog

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BoneAgentLocalRuntime/Catalog/BoneLocalModelDescriptor.swift`
- Create: `Sources/BoneAgentLocalRuntime/Catalog/BoneLocalModelCatalog.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalModelCatalogTests.swift`

**Steps:**
1. 编写失败测试，覆盖合法 Manifest、多下载源、重复 ID、路径穿越、非 HTTPS、非法 SHA-256、未知格式和 Runtime 版本不兼容。
2. 运行 `swift test --filter BoneLocalModelCatalogTests`，确认因 Product/类型缺失而失败。
3. 新增 Product/Target/Test Target，并实现最小 Codable 类型和严格校验。
4. 重跑定向测试，确认通过。

### Task 2: Safe Artifact Store

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Storage/BoneLocalModelStore.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalModelStoreTests.swift`

**Steps:**
1. 编写失败测试，覆盖安全路径、大小/SHA-256、原子安装、无效安装、删除和 `.partial` 清理。
2. 运行定向测试并确认 RED。
3. 使用注入的根目录与 FileManager 实现 Store；默认不决定 App 的存储位置。
4. 重跑定向测试并确认 GREEN。

### Task 3: Environment and Runtime Planning

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Environment/BoneLocalRuntimeEnvironment.swift`
- Create: `Sources/BoneAgentLocalRuntime/Planning/BoneLocalRuntimePlanner.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalRuntimePlannerTests.swift`

**Steps:**
1. 编写失败测试，区分模型理论上限、Runtime 上限、Host 上限、内存不足、输出预留、batch 与线程夹紧。
2. 运行定向测试并确认 RED。
3. 实现可注入环境快照、Runtime 约束与确定性 Plan。
4. 重跑定向测试并确认 GREEN。

### Task 4: Documentation and Verification

**Files:**
- Modify: `README.md`
- Modify: `API_BASELINE.md`
- Modify: `CHANGELOG.md`
- Create: `Documentation/LocalModels.md`

**Steps:**
1. 文档说明 Product 职责、Host 责任、Adapter seam 和非目标。
2. 运行 `swift test`。
3. 运行 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`。
4. 运行 `git diff --check` 与敏感信息扫描。
5. 按 Task 创建本地提交；不 push、不 tag。
