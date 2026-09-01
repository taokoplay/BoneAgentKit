# BoneAgentLlamaCpp Binary Package Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 创建独立 `BoneAgentLlamaCpp` Package、可复现 llama XCFramework 和真实 `BoneLlamaRuntime` Bridge。

**Architecture:** 独立 Package 通过本地/远端 BoneAgentKit 依赖取得协议层，通过 path-based binaryTarget 导入锁定 XCFramework。Runtime 隔离 C API 和生命周期，Binary provenance 与许可证作为发布门禁。

**Tech Stack:** Swift 5.9、Swift 6、SwiftPM、C/C++ llama.cpp、CMake、Xcode 26、Metal、Accelerate、XCTest。

---

## Task 1: Local repository skeleton and contracts

**Files:**
- Create: `BoneAgentLlamaCpp/Package.swift`
- Create: `README.md`, `LICENSE`, `NOTICE.md`, `.gitignore`
- Create: `Documentation/BuildAndProvenance.md`
- Create: `Tests/BoneAgentLlamaCppTests/BinaryContractTests.swift`

**Steps:**
1. 初始化独立本地 Git 仓库，不创建远端。
2. 写失败的 Binary contract 测试，要求 upstream commit、MIT license、provenance、slice metadata 和 binary path。
3. 运行测试确认 RED。
4. 添加最小文档与 manifest 结构使非 binary contract 通过。

## Task 2: Reproducible XCFramework build

**Files:**
- Create: `Scripts/build-llama-xcframework.sh`
- Create: `Scripts/verify-xcframework.sh`
- Create: `Provenance/llama-cpp.json`
- Create: `LICENSES/llama.cpp-LICENSE`
- Create: `Binaries/llama.xcframework`

**Steps:**
1. 下载锁定 Commit tarball并验证 commit identity。
2. 从上游构建脚本派生最小 iOS/macOS build；关闭 MTMD/Tools/Server/OpenMP/OpenSSL。
3. 生成 iOS device/simulator/macOS slices 与 dSYM。
4. 验证 minimum OS、architectures、module map、linked frameworks、UUID。
5. 计算 XCFramework tree checksum/provenance，并让 contract tests GREEN。

## Task 3: Runtime lifecycle seam

**Files:**
- Create: `Sources/BoneAgentLlamaCpp/BoneLlamaCppRuntime.swift`
- Create: `Sources/BoneAgentLlamaCpp/BoneLlamaCppBackend.swift`
- Create: `Sources/BoneAgentLlamaCpp/BoneLlamaCppConfiguration.swift`
- Create: `Tests/BoneAgentLlamaCppTests/BoneLlamaCppRuntimeContractTests.swift`

**Steps:**
1. 写可替换 C API seam 的 RED 测试：load/unload、半初始化释放、reload、cancel。
2. 实现 backend 一次初始化和 actor Runtime 状态机。
3. 定向测试 GREEN。

## Task 4: Tokenize, smoke and generation

**Files:**
- Modify: Runtime files
- Create: `Tests/BoneAgentLlamaCppTests/BoneLlamaCppGenerationTests.swift`

**Steps:**
1. 写 RED 测试：token buffer resize、context budget、decode failure、EOG、UTF-8、fixed seed、empty output。
2. 实现 smokeTest 和 generate。
3. 映射稳定 Runtime errors，不泄露路径/Prompt。
4. 定向与 strict tests GREEN。

## Task 5: Platform and release verification

**Steps:**
1. `swift test` 与 strict concurrency。
2. macOS arm64 本机 build/test。
3. iOS Simulator 和 generic device build。
4. provenance/license/checksum/diff checks。
5. 本地分功能 commit；不创建远端、不 push、不 tag。
6. 记录物理 iPhone 验证为预发布 blocker。
