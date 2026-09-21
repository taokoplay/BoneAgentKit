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

八个场景覆盖创建/读取/成功提交、拒绝非法 bundle 后无部分更新、并发 CAS、generation fencing、关闭后重新打开读取、独立连接的 CAS/fencing 一致性，以及业务 schema 不透明的 payload、初始 generation 契约。内存示例预期六项通过、两项 skipped；不能把 skipped 统计为通过。

两个新增场景是必需能力，不可 skipped：

- `opaqueCheckpointPayload`：以 generation 0 隔离 payload 行为，覆盖合法 JSON 对象、数组与标量、两种允许的 classification 和 retention，验证 create/load/commit 的字节与元数据保真。不能要求 Host typed schema，也不能解码再重编码。
- `creationLeaseGeneration`：覆盖 0、1、7、`UInt64.max` 的原样创建；验证正常换代、旧 revision 重放拒绝和 generation 溢出时的原子拒绝。它依旧需要合法通用 payload；如果 payload 探针失败，不能仅凭本项失败就断言 generation 实现错误。

初始化 create 抛错报告 `seedCreateRejected`，初始化 load 抛错报告 `seedLoadFailed`，不再把它们与目标 CAS/fencing 行为的失败混在一起。专用 payload 探针的 create/commit 抛错报告 `opaquePayloadRejected`，专用 generation 探针的 create 抛错报告 `creationGenerationRejected`；成功返回错误快照仍报告 `snapshotMismatch`。其他未归类操作异常保持 `operationFailed`。

这些是**失败阶段分类，不是底层根因诊断**：同一个 `corruptedCheckpoint` 或未知 Error 不能证明“Host schema 拒绝”，I/O 错误也可能出现在这些阶段。应联合两个独立探针与 Host 受控日志定位；套件不暴露原始错误，也不把 schema 更严格视为合法跳过理由。

真实 Host 工厂须提供自己的 `persistence`，并按能力注入：

- `reopenAfterClosingPrimary`：显式关闭主连接，再返回指向同一底层存储的新连接；suite 仍持有 persistence 引用，不能依赖 actor deinit 触发关闭。返回同一个 actor 不满足声明。
- `openIndependentConnection`：返回可与主连接并行工作的独立连接，不能只是同一 actor 的包装。
- `cleanup`：关闭所有连接并清理本场景拥有的测试资源；不得删除生产数据。成功、失败、跳过和取消均等待此回调。工厂返回之前失败，资源仍由工厂自行清理。

suite 在未取消的独立 Task 中执行 cleanup，之后传播取消；不要依赖调用任务的 Task-local 状态。Host 操作与 cleanup 都须合作退出，不提供强制超时。报告仅含固定场景、结果、失败分类和缺失能力，不包含原始 Error、路径、Run ID 或 payload。Host 自己的日志不在这一脱敏保证内。

这是行为探测，不是完整的线性化证明或进程崩溃/断电持久性认证。双任务 CAS 不保证触发数据库内部每种危险交错。重新打开与连接独立性由 Host 真实实现并声明，suite 无法验证物理存储拓扑。当前未提供真实 Adapter，跨连接和重开尚无真实持久层正例。

2026-09-05 核验 `alpha.11` 提交及仓库最近 Actions 运行列表均为空；Actions 已启用，但没有远端通过证据。最低 Swift 5.9 工具链仍未实测。

## 离线 SDK 环境模拟矩阵

`SDKEnvironmentMatrixTests` 是正式回归测试，不使用 API Key 或真实网络。它在注入 Transport
的边界模拟 OpenAI 兼容、Anthropic、Gemini 三种协议，覆盖：

| 环境 | 验证内容 |
| --- | --- |
| 正常响应 | 单次发送、完整响应、有效结果、同一关联 ID |
| HTTP 401/403/402/404/429/503 | 原错误映射、无隐式重试、失败响应仍有诊断 |
| 长度终态 | outputTruncated 保留，不交付部分正文 |
| 空响应/非法 JSON/数组根 | 诊断开启关闭不改变失败语义 |
| 超时/断网/连接中断 | 无 HTTP 摘要，不补造用量 |
| 执行中取消 | 先确认进入请求再取消，无重试 |
| 敏感 canary | 请求、正文、凭据、Header 值不进入诊断事件 |

矩阵由 6 个 XCTest 方法展开 52 个组合场景，不应把组合数量写成 XCTest 测试数量。

```bash
swift test --filter SDKEnvironmentMatrixTests
swift test --filter EventStreamTransportTests
swift test --filter AgentStreamingModeTests
swift test --filter ServerReasoningTests
swift test -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

流式连接和截止时间另由 `EventStreamTransportTests` 使用 URLProtocol 模拟；Agent 模式选择、
失败无回退和 Run 预算传递由 `AgentStreamingModeTests` 验证；Thinking 字段与预检由
`ServerReasoningTests` 验证。模拟 Transport 的网络错误不等同于真实 DNS/TLS/网关故障复现，
URLProtocol 也不能代替实际网络或供应商在线验收。生产准入仍需真实 Host 与最小线上 Smoke。

## Run 控制面契约验收

`BoneWorkflowRunControllerContractSuite` 使用同一 Persistence fixture 资源模型，但 factory 的入参是 `BoneWorkflowRunControllerContractCase`。每个场景创建隔离命名空间，同一场景可创建多个 Run；它不调用 reopen/独立连接能力，也没有 skipped 场景。

```swift
let observations = try await BoneWorkflowRunControllerContractSuite().run { _ in
    BoneWorkflowPersistenceContractFixture(
        persistence: BoneInMemoryWorkflowPersistence(),
        cleanup: {}
    )
}
for observation in observations {
    assert(observation.passed, "Control contract failed: \(observation.failures)")
}
```

五项必需场景：pending 起步、pause/resume 双 generation fencing、四类终态不可复活、cancelling 落盘早于停止闭包且不自动收口、恢复不改变 checkpoint 内容。fencing 探针直接向 Store 提交旧 generation＋新 revision，而不是仅验证 Controller 自己的前置检查。恢复场景证明的是不改动 checkpoint，不是对外部预算表的验证。

结果只有固定场景和失败枚举；`passed` 是 `failures.isEmpty` 的派生值。原始 Error、payload 与标识不进入报告。每项成功/失败/取消都等待未取消 Task 中的 cleanup，factory 抛错之前的资源仍由 factory 负责。操作须合作退出，不提供硬超时。

2026-09-21 本地回归在 `BoneInMemoryWorkflowPersistence` 与独立 `SerializedTestHost` 上执行两套契约。后者使用自有 Codable 存储信封与 CAS 实现，不包装内存参考实现，但仍只是 actor 内存测试适配器，**不等于外部第二 App、数据库、跨进程或磁盘持久性验收**。真实第二 Host 需用自己的工厂重新运行；停止闭包测试不证明真实 Worker 或未知 Effect 已停止。

```bash
swift test --filter WorkflowRunController
```

## 恢复扫描契约验收

`BoneWorkflowRecoveryScanContractSuite` 验证四项：空 scope、完整恢复候选集、扫描只读、混合坏行隔离计数。工厂提供 `BoneWorkflowRecoveryScanContractFixture`；其中 persistence 和 recoveryScan 必须是同一底层隔离 scope，fixture 初始为空。

```swift
let observations = try await BoneWorkflowRecoveryScanContractSuite().run { _ in
    let store = BoneInMemoryWorkflowPersistence()
    return BoneWorkflowRecoveryScanContractFixture(
        persistence: store,
        recoveryScan: store,
        cleanup: {}
    )
}
```

内存参考实现预期 3 passed、1 skipped(`injectQuarantinedRecord`)。这是**测试故障注入能力**缺失，不是生产协议可以不隔离坏行。真实 Host 应通过测试专用入口注入：每次新增一条独立的不可用存储记录（不能只是伪造扫描输出），不改动已有数据、不触碰生产命名空间。

注入场景在有效 Run 中混入第一条和第二条坏记录，逐次重复扫描，验证计数为 1、2 且不因读取累计；有效 Run 和被排除的正常终态均不得被修改。套件不依赖结果顺序，精确比较可信快照集合；snapshot 对象包含 payload，但输出报告只有固定场景、失败类型和 capability，不输出正文/ID/原始 Error。

取消与资源清理沿同一规则：fixture 返回后无论成功、失败、跳过或取消均等待未取消任务中的 cleanup；factory 返回前失败自己清理。无硬超时或自动修复。

2026-09-21 本地独立序列化测试 Host 已通过四项场景，故障注入覆盖不可解码字节与 Run/Checkpoint revision 不一致；负例覆盖漏计、累计计数、漏候选、扫描改写、坏行导致整批失败、取消与清理。基础设施错误传播测试只证明测试适配器的异常路径，不证明真实数据库把 I/O 错误正确区分为行级损坏。真实数据库隔离、scope 权限、完整性与物理坏行保留仍由 Host 验收。

```bash
swift test --filter WorkflowRecoveryScan
```

## 取消安全判定契约验收

`BoneWorkflowCancellationReadinessContractSuite` 有十一个必需场景：完整的未启动续执行、历史 unknown Effect、缺少 session 证据、历史 Effect 查询不完整、当前 session 存在 stage 活动、已有 observation、当前 session Effect、历史未提交 Effect、仅有 Receipt 未提交、preflight 拒绝、首次执行（零基序号 0）。工厂按 `BoneWorkflowCancellationReadinessContractCase` 在隔离测试数据中建立真实事实，返回 runID、只读 query、`verifyUnchanged` 与 cleanup。除场景注明差异外，其他 ready 条件须满足。

`verifyUnchanged` 必须从同一 backing 读取并核对 Run/session/Effect/stage/**已应用结果**与初始化事实一致，不能固定返回 true。套件重复读取并比较完整快照（Effect 行顺序除外），防止版本未变但投影漂移，再判定并核对源数据不变。十一个场景无 skipped；fixture 返回后的失败/取消仍等待 cleanup，factory 返回前失败由自身清理。报告仅包含固定场景和失败枚举，不包含标识、数据或原始 Error。

2026-09-21 独立内存事实 Host 覆盖上述十一个场景：所有场景都没有 Worker，只有持久事实决定 ready/rejected；unknown 故障场景保留已应用结果。负例验证隐藏 unknown/observation、误把仅 Receipt 当 committed、查询删除结果、证据版本或投影漂移会被契约拒绝。测试 Host 独立保存 Receipt 存在性与提交确认，并将一基 session 编号转换为零基；这仍不证明生产查询没有遗漏。该测试 Host 不是完整 session 存储，不证明实际 App 的 SQL 查询、跨表事务或外部副作用停止。

```bash
swift test --filter WorkflowCancellationReadiness
```

Host 仍需测试“检查后新增 Effect”的竞态：同一 Run revision 未变化时，完整证据版本也必须推进，原收口请求应被事务拒绝。SDK 单测验证改变证据重新评估会拒绝，不提供一个能原子控制任意 Host 表的写入协议。

## 持久预算契约验收

`BoneWorkflowRunBudgetContractSuite` 验证七项：requestLimit、finalReserve、deadline、clockFencing、reopenPreservesBudget、policyDrift、concurrentCAS。每项 factory 提供空隔离的 `BoneWorkflowRunBudgetContractFixture(store:reopen:cleanup:)`。

内存参考实现六项 passed、一项 skippedReopen；只有重开测试能力可跳过。独立序列化测试 Host 使用自有编码行、事务 actor 及显式连接关闭/新建，七项通过，但仅是 API 层重开模拟，不证明真实文件、跨进程、数据库隔离或设备 boot 身份可靠。

套件使用注入的固定时钟，不等待真实时间；决策按场景独立断言，完整状态与公共纯推进函数核对，再回读存储。并发同 revision 恰有一个赢家；额度拒绝后 attemptedRequests 必须持久递增，不能伪造返回快照但不保存。Host cleanup 关闭全部测试资源，取消仍等待 cleanup，factory 返回前异常由自身清理。

```swift
let observations = try await BoneWorkflowRunBudgetContractSuite().run { _ in
    BoneWorkflowRunBudgetContractFixture(
        store: BoneInMemoryWorkflowRunBudgetStore(),
        cleanup: {}
    )
}
```

```bash
swift test --filter WorkflowRunBudget
```

真实 Host 还需验证数据库写入后抛错/取消的未知提交窗口、跨连接事务、持久化失败时不误发请求、Run lease 与预算协同。套件报告只有固定场景/失败分类，无原始 Error、时钟值、Run ID 或数据库路径；预算快照本身不是安全诊断报告。

## 工作单元账本契约验收

`BoneWorkflowWorkLedgerContractSuite` 提供 pageCAS、generationFencing、knownFailure、splitStopsParent、preflightInFlight、aggregateCAS、concurrentCAS 七项必需场景，无 skipped。每场景 factory 返回空隔离的 `BoneWorkflowWorkLedgerContractFixture(store:cleanup:)`。

套件验证重复 revision/页号拒绝、旧 lease（即便使用当前 revision）拒绝、新 lease 不能冒认旧在途页、knownFailure 仍 partial 且占用页号、split 父不能再出页、非法 split 零写入、preflight 显示在途。成功回执完整回读，拒绝后快照不变，open 不重置工作进度。报告只有固定失败枚举，不包含 payload、ID 或原始异常。

2026-09-21 内存参考与独立编码命令日志测试 Host 均通过七项。后者每次 load 从自有日志重新重放合法转换，不包装内存参考 Store；仍是 actor 内存，不证明数据库唯一键、跨进程持久性或大规模日志性能。故障适配器覆盖伪造保存回执、漏 revision 校验、换代忽略旧 revision；便携契约验证跨单元共享 aggregate CAS 与同 revision 并发竞争；单测另覆盖提交顺序、旧代所有回写、终态不复活和 opaque 非 JSON 字节。

```swift
let observations = try await BoneWorkflowWorkLedgerContractSuite().run { _ in
    BoneWorkflowWorkLedgerContractFixture(
        store: BoneInMemoryWorkflowWorkLedgerStore(),
        cleanup: {}
    )
}
```

```bash
swift test --filter WorkflowWorkLedger
```

Host 必须补真实事务中父 split 与子创建的失败窗口、页唯一约束、同 Run 多连接竞争、预算与页准入协调，以及真实 Effect 结果未知时不错误标记 knownFailure。测试通过不授权自动重试或删除旧在途记录。

## 执行会话与续执行契约验收

`BoneWorkflowExecutionSessionContractSuite` 提供 admissionIntegrity、sequenceContinuity、nonceSingleUse、bindingMismatch、concurrentConsumption 五项必需场景，无 skipped。工厂提供空隔离的 `BoneWorkflowExecutionSessionContractFixture(store:cleanup:)`。

检查原始 admission 字节保真、改内容拒绝、零基序列严格连续、未 prepare 不可 consume、撤销/消费过 nonce 不复用、operation/effect/binding/nonce逐字段不匹配拒绝，以及并发消费仅一个赢家。拒绝后读回完整 ledger 不变；open 不重置历史。只有固定失败报告，不输出nonce、payload、标识或原始 Error。

```swift
let observations = try await BoneWorkflowExecutionSessionContractSuite().run { _ in
    BoneWorkflowExecutionSessionContractFixture(
        store: BoneInMemoryWorkflowExecutionSessionStore(),
        cleanup: {}
    )
}
```

```bash
swift test --filter WorkflowExecutionSession
```

2026-09-21 内存参考和自有编码行测试 Host 验证上述契约；Core 测试复用两种 payload 类型，并覆盖 hash已知向量、编码内容篡改、序列/许可/nonce墓碑损坏拒绝及原nonce不落盘。模拟消费前/后提交异常分别保留整个旧/新ledger。真实Host仍需验证多连接事务、一次性nonce消费与业务安全检查同一线性化点、提交回执丢失恢复、身份隔离和实际存储耐久性，不能仅凭内存契约通过声称接入完成。

## 旧工作页跨代对账契约

`BoneWorkflowWorkReconciliationContractSuite` 接收 `BoneWorkflowWorkReconciliationContractFixture`（store 必须支持独立对账协议、每场景空隔离 scope）。八项必需场景：committedRecovery、knownFailureRetention、targetFencing、responseIntegrity、concurrentCAS、concurrentUnits、concurrentLease、phaseCoverage。无 skipped；不支持恢复能力的原 Store 继续使用原工作账本套件，不能宣称通过本套件。

验证原进度保留、旧页 generation 和对账引用不丢失、页号/计数不回退、结果写回后当前代下一页可用，且旧 Worker 仍被拒。拒绝 stale revision、错误 Run/Unit/page/源代/当前代、替换已保存响应、成功降级失败、重复对账。并发仅一赢家；每次拒绝后读取完整原账本不变。

```swift
let results = try await BoneWorkflowWorkReconciliationContractSuite().run { _ in
    .init(store: BoneInMemoryWorkflowWorkLedgerStore(), cleanup: {})
}
```

```bash
swift test --filter WorkflowWork
```

2026-09-21 在内存参考及独立 Codable 命令日志 Host 验证；日志每次读取重放原命令/lease/对账事件，而不是包装参考 Store。模拟对账写入前/后丢失回执，确保重读得到完整旧/新状态；忽略CAS和伪造保存回执的故障适配器必须被检出。Host 上线前仍需证明真实数据库原子性、接管权限与对账事实同一校验边界、证据与原页的业务关联、旧请求不再产生副作用及业务结果不会重复应用。
