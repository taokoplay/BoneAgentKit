# BoneAgentKit

BoneAgentKit 是仓库内、可供多个 Swift 项目复用的 Agent 编排 Package。早期 Task 1–3 的最小 Runtime 已扩展为完整 Tool Calling、Workflow 与 Testing 边界。对外提供两个 Product：

- `BoneAgentKit`：生产推理、Tool Calling、Agent Runtime、Workflow、授权、Persistence 与副作用恢复契约；
- `BoneAgentTesting`：仅测试调用方使用的 Synthetic Provider、Scripted Engine、Recorder、Scenario、Assertions、Crash Harness 与 Safe Report。

生产 Product 不依赖 `BoneAgentTesting`。ParsingBook 的正文、角色 Parser、Evidence Grounder、数据库坐标、GRDB、手工字段保护和业务 Task DB 保留在 App Host。

## 能力概览

- OpenAI、Anthropic、Gemini 非流式 Tool Calling 与严格 Streaming 聚合；
- ordered Assistant Turn、0...N Tool Calls、Provider-scoped continuation；
- 默认串行、显式只读 parallel-safe 的确定性多 Tool 调度；
- 强类型 Tool Schema、六维影响、预算与 fail-closed Authorization Grant；
- 冻结 Workflow Plan、Run/Step/Attempt 状态机、组合 Persistence、CAS 与 lease generation fencing；
- Effect Intent / Effect Receipt、reconcile-first 与 `outcomeUnknown` 恢复决策；
- 可恢复 Agent Workflow Step 和提交后事件；
- 独立 `MinimalWorkflowHost` 跨项目编译运行示例；
- ParsingBook `CharacterAgentHost` 不透明引用、业务 Bridge、灰度路由、任务中心投影和 Live Smoke 边界。

## 文档导航

1. [快速开始](Documentation/GettingStarted.md)
2. [架构与模块边界](Documentation/Architecture.md)
3. [Tool Calling](Documentation/ToolCalling.md)
4. [Workflow 与恢复](Documentation/WorkflowAndRecovery.md)
5. [Testing](Documentation/Testing.md)
6. [安全与隐私](Documentation/SecurityAndPrivacy.md)
7. [Package 接入](Documentation/PackageIntegration.md)
8. [Character Host 接入](Documentation/CharacterHostIntegration.md)
9. [Provider 接入与扩展](Documentation/ProviderIntegration.md)
10. [来源与许可](Documentation/LicensingAndProvenance.md)

## 明确限制

- 不支持任意 DAG；当前是确定性 Workflow + 局部 Agent Step。
- 不保证 exactly-once；不可查询的外部副作用可能进入 `outcomeUnknown / recoveryRequired`。
- App 被系统终止后不会自动后台永久运行；下次启动通过新 lease 恢复。
- 自动 Contract、Synthetic Fixture 和 Simulator build 不能替代真机真实 Provider 验收。
- OpenAI、Anthropic、Gemini 的真实 Tool Calling Smoke 仍需 App 沙箱凭据、支持 Tool Calling 的模型以及用户明确确认联网和费用。
- Provider continuation、Prompt、正文、Tool 参数/结果和原始响应不得进入普通日志、事件或 Safe Report。

## 快速验证

```bash
swift test --package-path Frameworks/BoneAgentKit --disable-sandbox
python3 Tests/BoneAgentKit/bone_agent_kit_naming_regression.py
xcodebuild -project ParsingBook.xcodeproj \
  -scheme ParsingBook \
  -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build CODE_SIGNING_ALLOWED=NO
```
