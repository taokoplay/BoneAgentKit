import Foundation
import BoneAgentKit

struct Check: Codable, Sendable { let name: String; let passed: Bool }
struct ScenarioReport: Codable, Sendable {
    let scenario: Scenario
    let inputValues: [Int]
    let expectedTotal: Int
    let actualValues: [Int]?
    let actualTotal: Int?
    let taskOutcome: String
    let expectedOutcome: String
    let modelRunSucceeded: Bool
    let sdkError: String?
    let sourceUTF8Bytes: Int
    let reads: ReadCounts
    let businessInferenceCalls: Int
    let summaryInferenceCalls: Int
    let businessInputBytes: Int
    let summaryInputBytes: Int
    let compactionCount: Int
    let removedToolExchanges: Int
    let estimatedTokenReduction: Int
    let originalCardRemoved: Bool
    let referenceRecoveredFromSummary: Bool
    let trace: [String]
    var checks: [Check] = []
    var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }
}
struct RunReport: Encodable {
    let schemaVersion = 1
    let modelMode = "offline-deterministic"
    let liveProvider = false
    let scenarios: [ScenarioReport]
    let allChecksPassed: Bool
    init(scenarios: [ScenarioReport]) {
        self.scenarios = scenarios
        allChecksPassed = scenarios.allSatisfy(\.passed)
    }
}

func runScenario(_ scenario: Scenario, values: [Int]) async throws -> ScenarioReport {
    let audit = Audit()
    let text = "Synthetic report header\n" + String(repeating: "unused row\n", count: 110_000)
        + "VALUES=" + values.map(String.init).joined(separator: ",") + "\n"
    let snapshot = try BoneToolTextResourceSnapshot(id: "demo-" + UUID().uuidString, version: "v1", text: text)
    let store = ResourceStore(resource: snapshot, scenario: scenario)
    let context = DemoContext(store: store, scope: "demo")
    let engine = DemoEngine(scenario: scenario, audit: audit)
    let summary = DemoSummaryEngine(losesReference: scenario == .lostReference)
    let reader = BoneToolTextResourceReader<DemoContext> { request, context in
        try await context.store.read(request, scope: context.scope)
    }
    let tool = BoneToolTextResourceReadTool<DemoContext>(reader: reader)
    let contextPolicy: BoneContextManagementConfiguration?
    if scenario.usesCompaction {
        let window = try BoneContextWindowBudget(contextWindowTokens: 6_000, maximumOutputTokens: 256, source: .host)
        let summarizer = try BoneInferenceEngineContextSummarizer(engine: summary, modelID: "demo-summary",
            budget: .init(contextWindowTokens: 16_384, source: .host), costEstimator: { _ in 1 })
        contextPolicy = try .init(budgetProvider: { _ in window }, summarizer: summarizer,
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 256,
            maximumSummaryCallsPerRun: 2, fallbackToTrimming: false, minimumRecentToolExchangeCount: 1,
            receiptSink: { await audit.compacted($0) })
    } else { contextPolicy = nil }
    let budget = try BoneRunBudget(maximumInferenceCalls: 8, maximumToolCalls: 6,
        maximumInputBytes: 200_000, maximumOutputBytes: 100_000, maximumTurns: 6,
        maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 8)
    let agent = BoneAgent(inferenceEngine: engine,
        toolRegistry: try .init(tools: [BoneAnyAgentTool(LookupTool()), BoneAnyAgentTool(PaddingTool()), BoneAnyAgentTool(tool)]),
        toolContext: context, configuration: try .init(maximumSteps: 6, runBudget: budget,
            toolImpactPolicy: .init(maximumAllowed: BoneToolTextResourceReadTool<DemoContext>.definition.requiredImpact()),
            inferenceCostEstimator: { _ in 1 }, logging: .init(logger: SilentLogger()), contextManagement: contextPolicy))
    let expectedTotal = values.reduce(0, +)
    var actual: Delivery?
    var outcome = "failed"
    var runSucceeded = false
    var sdkError: String?
    do {
        let result = try await agent.run(modelID: "demo-model", messages: demoMessages)
        runSucceeded = true
        guard case .structured(let data) = result.output else { throw DemoFailure.missingData }
        let delivery = try JSONDecoder().decode(Delivery.self, from: data)
        actual = delivery
        let check = try await BoneInferenceValidatedOutputProcessor<Delivery, Int, Void>().process(delivery) { candidate in
            guard candidate.values == values, candidate.total == expectedTotal else {
                return .rejected(try .init(issue: .contractMismatch))
            }
            return .accepted(candidate.total)
        }
        switch check.validation {
        case .accepted: outcome = "accepted"; await audit.note("结果验收：值与合计正确，任务交付通过")
        case .rejected: outcome = "rejected"; await audit.note("结果验收：答案错误，拒绝交付；Agent 结束不等于任务完成")
        }
    } catch {
        if let known = error as? BoneAgentError {
            sdkError = String(describing: known)
            if known == .toolExecutionFailed && (scenario == .expired || scenario == .denied)
                || known == .inferenceFailed && scenario == .lostReference { outcome = "blocked" }
        } else { sdkError = "unexpectedFailure" }
        await audit.note("执行停止：\(sdkError ?? "unknown")，没有合格交付物")
    }
    let observations = try await engine.observations()
    let summaries = try await summary.observations()
    let (trace, receipts) = await audit.snapshot()
    let reads = await store.observations()
    var report = ScenarioReport(scenario: scenario, inputValues: values, expectedTotal: expectedTotal,
        actualValues: actual?.values, actualTotal: actual?.total, taskOutcome: outcome,
        expectedOutcome: scenario.expectedOutcome, modelRunSucceeded: runSucceeded, sdkError: sdkError,
        sourceUTF8Bytes: snapshot.reference.utf8ByteCount, reads: reads,
        businessInferenceCalls: observations.calls, summaryInferenceCalls: summaries.calls,
        businessInputBytes: observations.inputBytes, summaryInputBytes: summaries.inputBytes,
        compactionCount: receipts.count, removedToolExchanges: receipts.reduce(0) { $0 + $1.removedToolExchangeCount },
        estimatedTokenReduction: receipts.reduce(0) { $0 + $1.estimatedRequestTokenReduction },
        originalCardRemoved: observations.cardRemoved, referenceRecoveredFromSummary: observations.referenceRecovered,
        trace: trace)
    report.checks = [
        .init(name: "任务结果符合该场景预期", passed: outcome == scenario.expectedOutcome),
        .init(name: "原文超过 1 MiB，预览不超过 64 字节", passed: snapshot.reference.utf8ByteCount > 1_048_576 && reads.previewBytes == 64),
        .init(name: "发现工具只执行一次", passed: reads.lookups == 1),
        .init(name: "没有整体发送原文", passed: observations.inputBytes + summaries.inputBytes < snapshot.reference.utf8ByteCount / 10),
        .init(name: "原始任务和系统约束保留", passed: observations.messagesKept),
        .init(name: "调用次数有界且符合步骤", passed: observations.calls == scenario.expectedInferenceCalls),
        .init(name: "引用丢失时不读取，其余场景不重复读取", passed: reads.readAttempts == (scenario == .lostReference ? 0 : 1))
    ]
    if scenario.usesCompaction {
        report.checks.append(.init(name: "实际移除旧预览并使用摘要", passed: !receipts.isEmpty && report.removedToolExchanges >= 2
            && summaries.calls > 0 && summaries.calls <= 2 && observations.cardRemoved && report.estimatedTokenReduction > 0))
    } else {
        report.checks.append(.init(name: "未启用摘要时不发摘要请求", passed: receipts.isEmpty && summaries.calls == 0))
    }
    switch scenario {
    case .preview, .compressed:
        report.checks.append(.init(name: "交付值和合计独立核对", passed: actual?.values == values && actual?.total == expectedTotal && reads.successfulReads == 1))
        if scenario == .compressed { report.checks.append(.init(name: "引用确从摘要恢复", passed: observations.referenceRecovered)) }
    case .wrongAnswer:
        report.checks.append(.init(name: "运行成功但错误答案未交付", passed: runSucceeded && actual?.total == expectedTotal + 1 && outcome == "rejected"))
    case .expired, .denied, .lostReference:
        report.checks.append(.init(name: "被阻止时没有成功页或最终答案", passed: reads.successfulReads == 0 && actual == nil && !runSucceeded))
    }
    return report
}
