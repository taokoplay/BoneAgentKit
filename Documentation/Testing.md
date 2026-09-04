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

真实 OpenAI、Anthropic、Gemini Tool Calling 和角色 Agent Smoke 必须在 App 沙箱由用户显式 opt-in 并确认联网与费用。通用命令行 Harness 不扫描环境、Keychain、凭据存储或用户文件，也不导出真实响应。专用 `BoneAgentLiveProviderSmoke` 仅在同时给出 `--live`、`--confirm-network-and-costs`、Provider、精确模型 ID 和次数时读取所选 Provider 的单个固定凭据变量；`--dry-run` 不读取凭据且 Transport 永不发送。报告只允许 Provider、精确模型 ID、稳定执行身份、调用模式、次数、失败分类、聚合耗时和日期，不含 Prompt、Schema、候选值、Header、完整 URL 或模型正文。自动 Contract、Synthetic Fixture 和 Simulator build 不能替代真机验收。

```bash
swift run BoneAgentLiveProviderSmoke --dry-run

# 真实模式会联网并可能产生费用；只在明确授权的签发环境运行。
swift run BoneAgentLiveProviderSmoke --live --confirm-network-and-costs \
  --provider openai --model '<exact-model-id>' --iterations 100 \
  --invocation non-streaming
```

凭据变量固定为 `OPENAI_API_KEY`、`ANTHROPIC_API_KEY` 或 `GEMINI_API_KEY`；Runner 不枚举其它环境变量。真实报告仍只是候选证据，只有满足发布阈值并经审核后才能写入 bundled model Profile。

## 本地 Constraint Runtime

自动测试分三层：Canonical/Compiler 单测证明稳定身份与受支持 GBNF 方言；Engine/Probe Contract 测试证明请求级 Constraint、精确终止证据和能力门禁；真实 GGUF Smoke 才能证明具体 Runtime 的 Grammar Sampler、Tokenizer、Native Template 与 Stop Matcher 组合可用。前两层不能自动更新 bundled model Profile。

真实本地验收必须绑定精确 GGUF SHA-256、Runtime/Tokenizer/Template/Compiler/Grammar Runtime/Stop Matcher 版本、Context/Batch/最大输出配置，并在 iOS 真机覆盖直接 Enum、JSON Schema、受约束 Tool Call 与 Tool Result continuation。报告不得保存 Prompt、Schema/Grammar 正文、Stop String、模型输出或绝对路径。任一身份字段变化后必须重新验收。
