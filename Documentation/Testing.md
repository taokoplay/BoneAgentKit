# Testing 与 Harness

## Product 隔离

Package 提供独立 `BoneAgentTesting` Product，生产 `BoneAgentKit` Target 不依赖它。正式可复用实现位于 Testing Product；旧 Host runner 路径不属于本仓库验证入口。App Release 不应链接 Synthetic Fixture、Scripted Engine、Recorder、Scenario 或 Crash Harness。Package graph 回归持续验证此边界。

## 测试能力

- `BoneScriptedInferenceEngine`：按顺序消费强类型响应，记录请求，脚本耗尽稳定失败；
- `BoneAgentEventRecorder`：只记录不含正文的安全 Agent 事件；
- `BoneSyntheticProviderFixture`：仅接受 `https://synthetic.invalid`，在内存提供 HTTP/SSE；
- `BoneSafeHTTPRecorder`：只保存 method、scheme、host、path、白名单 Header 名、字节数、状态码和 streaming 标记；
- `BoneTestAssertion` 与 privacy canary：框架无关断言及敏感标记检测；
- `BoneAgentTestReport`：固定白名单 Codable 报告；
- `BoneAgentTestScenario`：只驻留内存、刻意不 Codable；
- `BoneCrashBoundaryHarness`：遍历 persistence commit 前、commit 后事件前、事件后下一工作前三个崩溃边界。

Fixture 不提供 cassette recorder，不自动落盘，不记录 URL query、Header 值、请求/响应 body 或 SSE data。

## 推荐矩阵

```bash
# 在仓库根运行；无需关闭 sandbox
swift test
swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift build -c release -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test --filter WorkflowStepControllerTests
swift test --filter WorkflowRecoveryTests
swift test --filter PersistenceContractTests
swift test --filter AuthorizationContractTests
swift run BoneAgentLiveProviderSmoke --dry-run
bash Scripts/check-public-documentation.sh
git diff --check
```

上述门禁分别验证默认语言模式与显式 Swift 6 严格模式。Package 声明最低 Swift 5.9；仅在较新编译器通过不等于最低工具链实测。Tool 参数和结果单项上限为 1 MiB。随机延迟测试必须固定 seed，并按 ordinal 断言结果，不能按完成时间。初始 Fixture 建立的使用成本目标是 1 小时内，一次 Tool 失败应能在 10 分钟内定位。

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

## CI 与 iOS SDK

`.github/workflows/ci.yml` 运行默认、严格并发、显式 Swift 6、Release、文档和无网络 smoke 门禁。配置存在不等于远端运行通过；不使用真实 Provider 凭据。

```bash
for scheme in BoneAgentKit BoneAgentTesting BoneAgentLocalModels BoneAgentLlama; do
  xcodebuild -scheme "$scheme" -destination 'generic/platform=iOS Simulator' \
    -configuration Release CODE_SIGNING_ALLOWED=NO build
done
```

2026-09-05 在 Xcode 26.0 / Swift 6.2 完成上述四库构建。Simulator SDK 编译不代表 iOS 13 真机执行或真实 Runtime 通过。真实 Host 必须另外运行 Debug/Release、数据库事务/lease expiry/崩溃恢复和设备资源测试；本仓库没有可代替这些验证的 Host runner。最低 Swift 5.9 工具链仍待独立验证。

## 本地 Constraint Runtime

自动测试分三层：Canonical/Compiler 单测证明稳定身份与受支持 GBNF 方言；Engine/Probe Contract 测试证明请求级 Constraint、精确终止证据和能力门禁；真实 GGUF Smoke 才能证明具体 Runtime 的 Grammar Sampler、Tokenizer、Native Template 与 Stop Matcher 组合可用。前两层不能自动更新 bundled model Profile。

真实本地验收必须绑定精确 GGUF SHA-256、Runtime/Tokenizer/Template/Compiler/Grammar Parser/Grammar Sampler/Stop Matcher 版本、Context/Batch/最大输出配置，并在 iOS 真机覆盖直接 Enum、JSON Schema、受约束 Tool Call 与 Tool Result continuation。报告不得保存 Prompt、Schema/Grammar 正文、Stop String、模型输出或绝对路径。任一身份字段变化后必须重新验收。


## Host 持久化契约验收

`BoneAgentTesting` 提供 `BoneWorkflowPersistenceContractSuite().run(factory:)`，每个场景要求工厂创建隔离测试命名空间。以下仅是内存接入示例，不是磁盘验收：

```swift
import BoneAgentKit
import BoneAgentTesting

let observations = try await BoneWorkflowPersistenceContractSuite().run { _ in
    BoneWorkflowPersistenceContractFixture(
        persistence: BoneInMemoryWorkflowPersistence(),
        cleanup: {}
    )
}
for observation in observations {
    switch observation.outcome {
    case .passed: break
    case .skipped(let capability): print("Missing capability: \(capability.rawValue)")
    case .failed(let failures): print(failures.map(\.rawValue))
    }
}
```

六个场景覆盖创建/读取/成功提交、拒绝非法 bundle 后无部分更新、并发 CAS、generation fencing、关闭后重新打开读取、独立连接的 CAS/fencing 一致性。内存示例预期四项通过、两项 skipped；不能把 skipped 统计为通过。

真实 Host 工厂须提供自己的 `persistence`，并按能力注入：

- `reopenAfterClosingPrimary`：显式关闭主连接，再返回指向同一底层存储的新连接；suite 仍持有 persistence 引用，不能依赖 actor deinit 触发关闭。返回同一个 actor 不满足声明。
- `openIndependentConnection`：返回可与主连接并行工作的独立连接，不能只是同一 actor 的包装。
- `cleanup`：关闭所有连接并清理本场景拥有的测试资源；不得删除生产数据。成功、失败、跳过和取消均等待此回调。工厂返回之前失败，资源仍由工厂自行清理。

suite 在未取消的独立 Task 中执行 cleanup，之后传播取消；不要依赖调用任务的 Task-local 状态。Host 操作与 cleanup 都须合作退出，不提供强制超时。报告仅含固定场景、结果、失败分类和缺失能力，不包含原始 Error、路径、Run ID 或 payload。Host 自己的日志不在这一脱敏保证内。

这是行为探测，不是完整的线性化证明或进程崩溃/断电持久性认证。双任务 CAS 不保证触发数据库内部每种危险交错。重新打开与连接独立性由 Host 真实实现并声明，suite 无法验证物理存储拓扑。当前未提供真实 Adapter，跨连接和重开尚无真实持久层正例。

2026-09-05 核验 `alpha.11` 提交及仓库最近 Actions 运行列表均为空；Actions 已启用，但没有远端通过证据。最低 Swift 5.9 工具链仍未实测。
