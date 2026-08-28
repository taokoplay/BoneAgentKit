# Testing 与 Harness

## Product 隔离

Package 提供独立 `BoneAgentTesting` Product，生产 `BoneAgentKit` Target 不依赖它。早期兼容 runner 仍可从 `Tests/BoneAgentKit/TestSupport` 编译辅助文件，但正式可复用实现位于 Testing Product。App Release 不应链接 Synthetic Fixture、Scripted Engine、Recorder、Scenario 或 Crash Harness。Package graph 回归持续验证此边界。

## 测试能力

- `BoneScriptedInferenceEngine`：按顺序消费强类型响应，记录请求，脚本耗尽稳定失败；
- `BoneAgentEventRecorder`：只记录不含正文的安全 Agent 事件；
- `BoneSyntheticProviderFixture`：仅接受 `https://synthetic.invalid`，在内存提供 HTTP/SSE；
- `BoneSafeHTTPRecorder`：只保存 method、scheme、host、path、白名单 Header 名、字节数、状态码和 streaming 标记；
- `BoneTestAssertion` 与 privacy canary：框架无关断言及敏感标记检测；
- `BoneAgentTestReport`：固定白名单 Codable 报告；
- `BoneAgentTestScenario`：只驻留内存、刻意不 Codable；
- `BoneCrashTestHarness`：遍历 persistence commit 前、commit 后事件前、事件后下一工作前三个崩溃边界。

Fixture 不提供 cassette recorder，不自动落盘，不记录 URL query、Header 值、请求/响应 body 或 SSE data。

## 推荐矩阵

```bash
swift test --package-path Frameworks/BoneAgentKit --disable-sandbox
zsh Tests/BoneAgentKit/run_bone_agent_runtime_tests.sh
zsh Tests/BoneAgentKit/run_bone_agent_workflow_step_tests.sh
zsh Tests/BoneAgentKit/run_bone_effect_recovery_tests.sh
zsh Tests/BoneAgentKit/run_bone_persistence_contract_tests.sh
zsh Tests/BoneAgentKit/run_bone_authorization_tests.sh
zsh Tests/BoneAgentKit/run_minimal_workflow_host_example.sh
python3 Tests/BoneAgentKit/bone_harness_testing_package_graph_regression.py
```

所有 Swift runner 使用 Swift 6、strict concurrency complete 和 warnings-as-errors。Tool 参数和结果单项上限为 1 MiB。随机延迟测试必须固定 seed，并按 ordinal 断言结果，不能按完成时间。初始 Fixture 建立的使用成本目标是 1 小时内，一次 Tool 失败应能在 10 分钟内定位。

## 事件和 Checkpoint

`BoneAgentEvent` 的兼容观察序列是 `runStarted → toolCallStarted → toolCallFinished → runFinished`，它不是持久事实源。Workflow Agent Step 在 inference response 和 Tool result 后先 persistence commit，再发布 Workflow 安全事件。取消测试需同时断言：cancel 意图已持久化、迟到结果未提交、终态不可复活。

## 真实 Provider

真实 OpenAI、Anthropic、Gemini Tool Calling 和角色 Agent Smoke 必须在 App 沙箱由用户显式 opt-in 并确认联网与费用。命令行 Harness 不读取凭据，不导出真实响应。报告只允许稳定状态、长度和计数；未知事实为 `unavailable`。自动 Contract、Synthetic Fixture 和 Simulator build 不能替代真机验收。
