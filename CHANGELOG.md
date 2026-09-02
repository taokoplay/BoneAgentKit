# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本采用 SemVer。

## [Unreleased]

## [0.2.0-alpha.5] - 2026-09-02

### Added

- `BoneLlamaInferenceEngine` 支持显式注入 `BoneLlamaToolCalling` 后按实例声明 `.toolCalling`；新增严格 ChatML + JSON envelope 的 `BoneLlamaJSONToolCallingCodec`，覆盖 Tool schema、并行调用和 Tool Result 续轮，默认仍为 text-only。
- 新增 `BoneModelCapabilityProfile` 与证据来源，供云端 Provider Catalog 和本地模型 Descriptor 可选声明细粒度推理能力；本地 Probe 报告实际验证的 `.text` / `.toolCalling` 能力。

### Changed

- Provider 与 Llama Engine 在模型 Profile 已知时将其与实现能力取交集；`BoneAgent` 在 `runStarted` 前改用请求级 `resolvedCapabilities` 预检。
- 新增公开 `BoneAgentKitVersion` 运行时版本镜像，并通过测试约束 README 与 CHANGELOG 的版本一致性；SwiftPM 发布版本仍以 Git Tag 为准。

## [0.2.0-alpha.4] - 2026-09-01

### Changed

- README 重构为开源 SDK 门面，统一 Product、安装、能力、架构、限制与许可层级；新增分类文档地图。
- 扩展公开说明门禁，检查项目专有术语、本机路径、README 契约、Markdown 相对链接和标题层级。

## [0.2.0-alpha.3] - 2026-09-01

### Changed

- 公开说明改为通用 App Host 边界，不再包含任何调用项目名称或 Host 专有实现细节。

## [0.2.0-alpha.2] - 2026-09-01

### Changed

- BoneAgentKit 源码和文档从 proprietary 许可切换为 `AGPL-3.0-only`。
- Provider 渠道 PNG 与其中涉及的第三方商标明确排除在 AGPL 授权范围外；历史 tag 的许可不追溯变更。

## [0.2.0-alpha.1] - 2026-09-01

### Added

- 新增 `BoneAgentLocalRuntime` Product，提供本地模型 Catalog、多下载源 Artifact、安全安装存储、环境快照与确定性运行规划。
- 新增 actor 下载 Coordinator、可注入 Transport 和默认 URLSession Transport，支持磁盘预检、可信重定向、进度、暂停/恢复/取消及受控多源切换。
- 新增本地模型 Artifact Inspector、Adapter Probe 契约和 metadata/load/smoke 两阶段 Probe Coordinator。
- 新增 `BoneAgentLlama` Product，提供无二进制耦合的 Runtime seam、load/smoke Probe、通用 ChatML encoder 与 text-only `BoneInferenceEngine`。
- `BoneLlamaInferenceEngine` 提供当前模型状态快照和 AsyncStream 实时通知；可选 `BoneLlamaRuntimeStateObserving` 供具体 Runtime 暴露加载、生成、取消、卸载与失败状态。
- `BoneAgentKit` 内置 14 个 Provider 渠道的 42 个 1x/2x/3x PNG，资源实现 Target 不作为独立 Product 暴露。
- `BoneInferenceProviderCatalog.iconData(iconID:scale:)` fail-closed 资源接口与完整性测试。
- Host compatibility manifest。
- 实例与请求级 `BoneResolvedInferenceCapabilities`。
- BoneAgentKit 现代化基线和发布契约。

### Changed

- 推理消息解码改为显式 one-of 校验，同时兼容旧 assistant 文本消息。
- Custom OpenAI-compatible endpoint 不再默认承诺原生结构化输出。
- `.commitUncertain` 可恢复，但禁止自动继续或重试。

### Fixed

- Swift 6 strict concurrency 测试阻断。
- Workflow Step controller 交错运行的身份回归覆盖。
- `BoneInferenceHTTPTransport` 文档边界回归。

## 版本列车

### 0.x-hardening

只交付正确性、恢复语义、安全、严格并发和分发治理；不切换 Host 默认行为。

### 0.x-modularization

只交付 target 拆分与兼容入口；不同时启用 managed context 或本地 Runtime。

### 1.0.0

仅在 hardening、modularization、法律审计、真实 Provider Smoke 和宿主兼容门禁全部通过后签发。
