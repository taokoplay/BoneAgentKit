# BoneLlama Runtime State Observation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 为 BoneLlama Runtime 和 Inference Engine 增加安全快照与 AsyncStream 实时状态通知，并在真实 llama.cpp 与物理 iPhone 上验证页面能获知操作开始和完成。

**Architecture:** 保持 `BoneLlamaRuntime` 源兼容，新增可选 `BoneLlamaRuntimeStateObserving`。Engine Session 独立维护带 model ID 的公开状态中心，使用 `bufferingNewest(1)` 多播并立即回放当前 Snapshot；`BoneLlamaCppRuntime` 维护原生状态中心供直接观察。

**Tech Stack:** Swift 5.9/6、Swift Concurrency、AsyncStream、SwiftPM、XCTest、llama.cpp、Xcode/devicectl。

---

### Task 1: State value contracts

**Files:**
- Create: `Sources/BoneAgentLlama/Runtime/BoneLlamaRuntimeState.swift`
- Modify: `Sources/BoneAgentLlama/Runtime/BoneLlamaRuntime.swift`
- Create: `Tests/BoneAgentLlamaTests/BoneLlamaRuntimeStateTests.swift`

**Steps:**
1. 写失败测试：初始 Snapshot、phase、revision、配置/失败值语义和 Engine model ID 投影。
2. 运行 `swift test --filter BoneLlamaRuntimeStateTests`，确认类型缺失 RED。
3. 新增 phase、Runtime/Model Snapshot 和可选观察协议。
4. 重跑定向测试确认 GREEN。
5. 运行 strict concurrency 定向测试。

### Task 2: Engine state multicast

**Files:**
- Modify: `Sources/BoneAgentLlama/Inference/BoneLlamaInferenceEngine.swift`
- Modify: `Tests/BoneAgentLlamaTests/BoneLlamaInferenceEngineTests.swift`

**Steps:**
1. 写失败测试：新订阅立即收到 `notLoaded`；首次 infer 收到 `loading → loaded → generating → loaded`；unload 收到 `unloading → notLoaded`；失败进入 `failed`；两个订阅者序列一致。
2. 运行定向测试确认 API/行为 RED。
3. 在 Session 实现 revision、continuation 字典、`bufferingNewest(1)`、onTermination 清理和状态发布。
4. 在 Engine 暴露 snapshot/stream API，不改变 `BoneInferenceEngine` 协议。
5. 定向和 strict 测试 GREEN。

### Task 3: llama.cpp Runtime state

**Files:**
- Modify: `/Users/xutaoyu/CodeSource/BonePackage/BoneAgentLlamaCpp/Sources/BoneAgentLlamaCpp/BoneLlamaCppRuntime.swift`
- Modify: `/Users/xutaoyu/CodeSource/BonePackage/BoneAgentLlamaCpp/Tests/BoneAgentLlamaCppTests/BoneLlamaCppRuntimeTests.swift`
- Modify: `/Users/xutaoyu/CodeSource/BonePackage/BoneAgentLlamaCpp/Tests/BoneAgentLlamaCppTests/BoneLlamaCppRealModelTests.swift`

**Steps:**
1. 写失败测试：直接 Runtime 初始回放、缺失模型 `loading → failed`、真实 GGUF `loading → loaded → generating → loaded → unloading → notLoaded`。
2. 运行定向测试确认 RED。
3. 让 `BoneLlamaCppRuntime` 实现可选观察协议，集中所有状态转换和 revision。
4. 确保失败状态只含类型化错误，不含路径或原始日志。
5. 真实 GGUF 和 strict tests GREEN。

### Task 4: Documentation and API baseline

**Files:**
- Modify: `README.md`
- Modify: `Documentation/LocalModels.md`
- Modify: `API_BASELINE.md`
- Modify: `CHANGELOG.md`
- Modify: `/Users/xutaoyu/CodeSource/BonePackage/BoneAgentLlamaCpp/README.md`

**Steps:**
1. 文档说明完成语义、订阅示例、首版无百分比及取消限制。
2. 更新公开 API baseline 和 CHANGELOG。
3. 运行 diff/privacy scan。

### Task 5: Physical iPhone state notification

**Files:**
- Modify temporary host: `/Users/xutaoyu/.proma/agent-workspaces/default/82ab65e3-d998-46f9-b9e7-f68edcb62835/device-test-host/Sources/DeviceTestApp.swift`

**Steps:**
1. 让页面订阅 Runtime state stream，并把 phase/revision 序列写入设备报告。
2. warnings-as-errors 构建、签名并安装到已连接 iPhone 13 Pro。
3. 启动测试并从 app data container 拉取 JSON。
4. 验证包含 load/generate/unload 的开始与完成序列、0 failures 和无崩溃日志。
5. 临时 Host 不进入 Git。

### Task 6: Full verification and local commits

**Steps:**
1. BoneAgentKit 定向、完整和 Swift 6 strict tests。
2. BoneAgentLlamaCpp 默认、真实 GGUF、strict 和 XCFramework contract。
3. generic iOS Simulator/device build。
4. 敏感路径、模型权重、凭据、Prompt/输出和 diff checks。
5. BoneAgentKit 按设计与功能创建本地提交；BoneAgentLlamaCpp 按状态实现创建本地提交。
6. 不 push、tag、merge 或 release；复验 ParsingBook 仍只有用户原有 `MEMORY.md` 修改。
