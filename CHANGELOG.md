# Changelog

本文件遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)；版本采用 SemVer。

## [Unreleased]

### Added

- ParsingBook compatibility manifest。
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

只交付正确性、恢复语义、安全、严格并发和分发治理；不切换 ParsingBook 默认行为。

### 0.x-modularization

只交付 target 拆分与兼容入口；不同时启用 managed context 或本地 Runtime。

### 1.0.0

仅在 hardening、modularization、法律审计、真实 Provider Smoke 和宿主兼容门禁全部通过后签发。
