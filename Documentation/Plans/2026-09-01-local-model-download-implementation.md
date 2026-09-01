# Local Model Download Module Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 `BoneAgentLocalRuntime` 增加安全、可注入、支持暂停恢复与多源故障切换的本地模型下载 Module。

**Architecture:** 使用公开的 Sendable Transport 协议隔离网络 I/O，以 actor Coordinator 串行化每个模型的状态与操作；默认 URLSession Transport 执行 HTTP 下载和逐跳重定向校验。下载完成统一进入现有 Store 做大小/SHA-256 验证与原子安装。

**Tech Stack:** Swift 5.9、Foundation、FoundationNetworking（兼容条件导入）、URLSession、Swift Concurrency、XCTest、Swift 6 strict concurrency。

---

## Task 1: Download contracts and security policy

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Download/BoneLocalModelDownloadModels.swift`
- Create: `Sources/BoneAgentLocalRuntime/Download/BoneLocalModelDownloadSecurityPolicy.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalModelDownloadSecurityPolicyTests.swift`

**Steps:**
1. 写失败测试，覆盖 exact/wildcard Host、HTTPS、未知 Host、降级和源排序。
2. 运行 `swift test --filter BoneLocalModelDownloadSecurityPolicyTests`，确认类型缺失 RED。
3. 最小实现状态、错误、策略、进度、Transport request/result/event 及 security policy。
4. 重跑定向测试，确认 GREEN。
5. `git diff --check`，暂不提交，等待 Coordinator 接口稳定。

## Task 2: Actor coordinator and injected transport

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Download/BoneLocalModelDownloadCoordinator.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneLocalModelDownloadCoordinatorTests.swift`

**Steps:**
1. 写 fixture transport 和失败测试，覆盖空间不足、进度、完成校验、网络/5xx 切源、4xx/安全/校验失败不切源。
2. 运行 `swift test --filter BoneLocalModelDownloadCoordinatorTests`，确认 Coordinator 缺失 RED。
3. 实现 actor、单模型任务、源排序、状态流和 Store 安装。
4. 重跑定向测试，确认 GREEN。
5. 增加暂停/恢复/取消失败测试并确认 RED。
6. 最小实现 opaque resume data、staging 清理和取消语义，确认 GREEN。

## Task 3: Default URLSession transport

**Files:**
- Create: `Sources/BoneAgentLocalRuntime/Download/BoneURLSessionLocalModelDownloadTransport.swift`
- Create: `Tests/BoneAgentLocalRuntimeTests/BoneURLSessionLocalModelDownloadTransportTests.swift`

**Steps:**
1. 写自定义 URLProtocol 测试，覆盖成功落盘、HTTP 分类、重定向安全回调和取消。
2. 运行定向测试，确认 Transport 缺失 RED。
3. 实现 delegate-backed URLSession Transport，所有共享状态由 actor/锁保护并符合 Sendable。
4. 重跑定向测试，确认 GREEN。
5. 运行 strict concurrency 定向测试。

## Task 4: Documentation and API contract

**Files:**
- Modify: `Documentation/LocalModels.md`
- Modify: `README.md`
- Modify: `API_BASELINE.md`
- Modify: `CHANGELOG.md`

**Steps:**
1. 写明 Coordinator、默认 Transport、安全切源、暂停恢复和 Host 责任。
2. 明确非目标：Background Session、业务文案、蜂窝授权、Runtime Adapter。
3. 运行 `git diff --check`。

## Task 5: Verification and local commits

**Steps:**
1. 运行所有 `BoneAgentLocalRuntimeTests`。
2. 运行 `swift test`。
3. 运行 `swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors`。
4. 运行 Package graph、`git diff --check`、敏感模式扫描。
5. 按设计/契约、Coordinator、URLSession Transport、文档拆分本地 commit。
6. 确认未 push/tag/merge，且任何 App Host 均未被修改。
