# BoneAgentKit 现代化基线

> 采集时间：2026-08-31（GMT+8）
>
> 基线提交：`9da1b3eaeaa7066dec06d591801b47f2a4019fbb`

## 基线发现

- 干净 Git HEAD 缺少 14 个被 `.gitignore` 隐藏、但当前开发目录参与编译的源码与测试文件。
- 缺少这些文件时，SwiftPM 默认构建失败，公开 API baseline 只有 191 个声明。
- 恢复这 14 个现有文件后，SwiftPM 默认模式执行 101 个测试且全部通过，公开 API baseline 为 203 个声明。
- Swift 6 strict concurrency 最初被两类测试问题阻断：actor 跨隔离域返回 `[String: Any]`，以及 URLProtocol fixture 使用共享 `static var`。
- 依赖边界回归最初因 README、Architecture 与 SecurityAndPrivacy 未完整说明统一 `BoneInferenceHTTPTransport` 和 `AIProviderKit` 迁移边界而失败。
- Package 当前包含 42 个 Provider PNG、1 个 Provider 配置 JSON，共 43 个资源文件；尚无 `LICENSE`、`NOTICE` 或图标归因文件。

## 第一批修复后的门禁

```bash
swift test --package-path Frameworks/BoneAgentKit
swift test --package-path Frameworks/BoneAgentKit \
  -Xswiftc -strict-concurrency=complete \
  -Xswiftc -warnings-as-errors
python3 Tests/BoneAgentKit/bone_harness_public_api_baseline.py
python3 Tests/BoneAgentKit/bone_inference_dependency_boundary_regression.py
git diff --check
git diff --cached --check
```

预期结果：

- SwiftPM 默认与 strict 模式均执行 101 个测试，0 failure；
- 公开 API baseline 保持 203 个声明；
- 依赖边界回归通过；
- diff whitespace 检查通过。

## 尚未关闭的发布缺口

- 发布契约、SemVer、CHANGELOG、API baseline 文档尚未建立；
- LICENSE、NOTICE、Provider 图标来源和商标说明尚未补齐；
- Host compatibility manifest 尚未建立；
- 严格消息 one-of 解码、实例级 capability、可执行 checkpoint、安全 Tool Result、Prepared Request 和本地 Runtime 尚未实施。
