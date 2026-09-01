# BoneAgentLlamaCpp Binary Package Design

**Date:** 2026-09-01
**Status:** Approved

## Goal

建立独立私有 `BoneAgentLlamaCpp` Swift Package，从锁定的 llama.cpp Commit 可复现构建多平台 XCFramework，并实现 `BoneLlamaRuntime`，同时保持 BoneAgentKit 基础 Products 不依赖 C/C++ 二进制。

## Repository Boundary

`BoneAgentLlamaCpp` 是独立仓库，依赖 `BoneAgentKit` 的 `BoneAgentLlama` Product。依赖方向只能是 Binary Adapter → Protocol Adapter。BoneAgentKit 不增加 binary target，不抬高现有 iOS 13/macOS 13 平台契约。

Binary Package 第一版平台为 iOS 15 与 macOS 13；只在 Host 明确依赖时下载和链接。

## Upstream and Build

- Repository: `https://github.com/ggml-org/llama.cpp`
- Commit: `daef7b6874397a5a7c3d7e38b55e2ee0adf7da38`
- License: MIT
- Slices: ios-arm64、ios-arm64_x86_64-simulator、macos-arm64_x86_64
- GGML Metal: ON
- Embedded Metal library: ON
- Accelerate/BLAS: ON
- OpenMP/OpenSSL/Server/Tools/Examples/Tests/MTMD: OFF

仓库保留构建脚本、上游许可证、provenance manifest、XCFramework checksum 和 release symbol 归档说明。第一版本地 Package 使用 path-based binary target；未来远端 Release Asset 必须以 zip + SwiftPM checksum 发布。

## Runtime Architecture

`BoneLlamaCppRuntime` 作为 actor/串行执行器实现 `BoneLlamaRuntime`。进程级 backend 初始化由独立协调器确保一次性、线程安全。每个 Runtime 实例拥有自己的 model/context/sampler，不共享可变推理状态。

配置映射：context/batch/thread 来自 `BoneLocalRuntimePlan`；GPU layer 使用 `.automatic` 策略；generation seed 可注入，默认随机，测试和 smoke 使用固定 seed。

## Lifecycle

- `load`: 验证文件存在，清理旧状态，初始化 backend，加载 model 和 context；半初始化失败必须释放。
- `smokeTest`: 使用无业务语义的最小 token/decode 检查，不返回生成内容。
- `generate`: 清理 KV、tokenize、验证 context budget、decode prompt、确定性/随机 sampler、逐 token decode、UTF-8 组装。
- `cancel`: 设置线程安全 cancellation flag；decode loop 在 token 边界停止。
- `unload`: 释放 sampler/context/model，使 Runtime 可重新 load。

## Security and Privacy

不记录模型绝对路径、Prompt、Token、输出或底层 assertion 字符串。C API 错误映射为稳定 `BoneLlamaRuntimeError`。模型权重不进入仓库。Binary provenance 记录 build toolchain 与哈希，但不记录开发者主目录。

## Distribution

第一阶段仅本地 Git 仓库和本地 commits，不创建远端。待真实 iOS/macOS 验证通过后再单独批准创建私有 GitHub 仓库、上传 binary/dSYM 和发布预发布 tag。

## Verification

- Synthetic lifecycle tests and strict concurrency
- macOS real binary load/smoke/generate with tiny verified GGUF fixture when available
- iOS Simulator build
- generic iOS device build
- XCFramework slice/minimum OS/module map/otool/dSYM UUID checks
- provenance and license contract tests
- physical iPhone thermal/background/performance remains a release blocker until manually verified
