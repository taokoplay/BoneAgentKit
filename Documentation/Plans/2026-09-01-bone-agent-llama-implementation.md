# BoneAgentLlama Protocol Adapter Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 新增不绑定 llama.cpp 二进制的 `BoneAgentLlama` Product，并实现 Runtime seam、Probe Adapter、ChatML encoder 和 text-only `BoneInferenceEngine`。

**Architecture:** Product 依赖 BoneAgentKit 与 BoneAgentLocalRuntime，通过 Runtime factory 注入真实或 Synthetic Runtime。Probe 使用隔离 Runtime；Engine 使用 actor Session 串行化模型生命周期，按真实能力 fail closed。

**Tech Stack:** Swift 5.9、SwiftPM、Foundation、Swift Concurrency、XCTest、Swift 6 strict concurrency。

---

## Task 1: Product and Runtime contracts

**Files:**
- Modify: `Package.swift`
- Create: `Sources/BoneAgentLlama/Runtime/BoneLlamaRuntime.swift`
- Create: `Sources/BoneAgentLlama/Runtime/BoneLlamaRuntimeModels.swift`
- Create: `Tests/BoneAgentLlamaTests/BoneLlamaRuntimeModelsTests.swift`

**Steps:**
1. 写失败测试，覆盖 plan→configuration、generation options 夹紧和类型化错误。
2. 运行 `swift test --filter BoneLlamaRuntimeModelsTests`，确认 Product/类型缺失 RED。
3. 新增 Product/Target/Test Target 与最小 Runtime seam。
4. 重跑确认 GREEN。

## Task 2: Probe Adapter

**Files:**
- Create: `Sources/BoneAgentLlama/Probe/BoneLlamaRuntimeProbeAdapter.swift`
- Create: `Tests/BoneAgentLlamaTests/BoneLlamaRuntimeProbeAdapterTests.swift`

**Steps:**
1. 写 Synthetic Runtime factory 和 RED 测试：load、smoke、unload 顺序与错误分类。
2. 实现隔离 Runtime factory、descriptor 和 Probe 映射。
3. 重跑确认 GREEN。

## Task 3: Prompt encoder

**Files:**
- Create: `Sources/BoneAgentLlama/Prompt/BoneLlamaPromptEncoding.swift`
- Create: `Sources/BoneAgentLlama/Prompt/BoneLlamaChatMLPromptEncoder.swift`
- Create: `Tests/BoneAgentLlamaTests/BoneLlamaChatMLPromptEncoderTests.swift`

**Steps:**
1. 写 RED 测试：system/user/legacy assistant 编码；tools、tool results、assistant turn、continuation、structured/reasoning 拒绝。
2. 实现无业务人格的通用 ChatML encoder。
3. 重跑确认 GREEN。

## Task 4: Text-only BoneInferenceEngine

**Files:**
- Create: `Sources/BoneAgentLlama/Inference/BoneLlamaInferenceEngine.swift`
- Create: `Tests/BoneAgentLlamaTests/BoneLlamaInferenceEngineTests.swift`

**Steps:**
1. 写 RED 测试：capabilities、model mismatch、load/reuse、generation 映射、空响应、unsupported request。
2. 实现 actor Engine、Runtime factory、Prompt encoder 注入与 text response。
3. 重跑确认 GREEN。
4. strict concurrency 定向验证。

## Task 5: Documentation and verification

**Files:**
- Modify: `README.md`
- Modify: `API_BASELINE.md`
- Modify: `CHANGELOG.md`
- Modify: `Documentation/LocalModels.md`

**Steps:**
1. 文档说明 Product、真实能力、Binary bridge seam 和非目标。
2. 运行 BoneAgentLlama 定向、完整和 strict tests。
3. 运行 Package graph、diff、敏感扫描。
4. 按设计、runtime/probe、prompt/engine、docs 拆分本地 commit。
5. 确认不 push/tag/merge，且任何 App Host 均未修改。
