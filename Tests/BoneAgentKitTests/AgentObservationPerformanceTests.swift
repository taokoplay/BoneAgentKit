import Foundation
#if canImport(Darwin)
import Darwin
#endif
import XCTest
@testable import BoneAgentKit

final class AgentObservationPerformanceTests: XCTestCase {
    /// Same workload before/after optimization. Timings are diagnostic, never flaky pass/fail thresholds.
    func testLongRunSnapshotWorkload() throws {
        var ledger = BoneAgentTokenLedger()
        let runID = UUID()
        let usage = Self.usage
        let start = ProcessInfo.processInfo.systemUptime
        var last: BoneAgentTokenSnapshot?
        for index in 0..<2_000 {
            let id = UUID()
            ledger.begin(id: id, modelID: "model", step: index + 1, purpose: .business, now: Double(index))
            _ = ledger.observe(usage, id: id, provider: true)
            _ = ledger.finish(id: id, state: .responseReceived, usage: usage, now: Double(index) + 0.5)
            let value = ledger.snapshot(runID: runID, now: Double(index) + 0.5)
            XCTAssertEqual(value.statistics.stepCount, index + 1)
            last = value
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let value = try XCTUnwrap(last)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 200_000)
        XCTAssertEqual(value.requests.count, 64)
        XCTAssertEqual(value.omittedRequestCount, 1_936)
        XCTAssertTrue(ledger.requestClocks.isEmpty)
        print("OBSERVATION_BENCHMARK requests=2000 elapsedSeconds=\(elapsed) retainedRequests=\(value.requests.count)")
    }

    func testRetentionDoesNotChangeUnknownValuesOrWeightedTiming() throws {
        let policy = try BoneAgentObservationPolicy(maximumRequestDetails: 3, maximumToolDetails: 0)
        var ledger = BoneAgentTokenLedger(policy: policy)
        var firstID: UUID?
        for index in 0..<1_000 {
            let id = UUID()
            if index == 0 { firstID = id }
            ledger.begin(id: id, modelID: "model", step: index + 1, purpose: index % 2 == 0 ? .business : .summary, now: 0)
            ledger.requestClocks[id]?.observe(.requestStarted(liveTiming: true), now: 0)
            ledger.requestClocks[id]?.observe(.firstOutputToken, now: 2)
            ledger.requestClocks[id]?.observe(.responseFinished, now: 6)
            _ = ledger.finish(id: id, state: index % 10 == 0 ? .cancelled : .responseReceived,
                usage: index % 10 == 0 || index % 10 == 1 ? nil : Self.usage, now: 6)
        }
        let value = ledger.snapshot(runID: UUID(), now: 6)
        XCTAssertEqual(value.requests.count, 3)
        XCTAssertEqual(value.total.requestCount, 1_000)
        XCTAssertEqual(value.total.responseCount, 900)
        XCTAssertEqual(value.total.reportedResponseCount, 800)
        XCTAssertEqual(value.total.knownUsage?.outputTokens, 16_000)
        XCTAssertEqual(value.business.requestCount, 500)
        XCTAssertEqual(value.summaries.requestCount, 500)
        XCTAssertEqual(value.statistics.averageTimeToFirstTokenSeconds, 2)
        XCTAssertEqual(value.statistics.outputTokensPerSecond, 5)
        XCTAssertEqual(value.statistics.throughputSampleCount, 400)
        XCTAssertFalse(value.total.isComplete)
        XCTAssertFalse(ledger.observe(Self.usage, id: try XCTUnwrap(firstID), provider: true))
        XCTAssertFalse(ledger.finish(id: try XCTUnwrap(firstID), state: .responseReceived, usage: Self.usage, now: 10))
    }

    func testActiveRequestsAndOldSnapshotsSurviveRingWrap() throws {
        var ledger = BoneAgentTokenLedger(policy: try .init(maximumRequestDetails: 2))
        let runID = UUID(), first = UUID()
        ledger.begin(id: first, modelID: "a", step: 1, purpose: .business, now: 0)
        _ = ledger.finish(id: first, state: .responseReceived, usage: Self.usage, now: 1)
        let frozen = ledger.snapshot(runID: runID, now: 1)
        for step in 2...20 {
            let id = UUID()
            ledger.begin(id: id, modelID: "a", step: step, purpose: .business, now: 0)
            _ = ledger.finish(id: id, state: .responseReceived, usage: Self.usage, now: 1)
        }
        let active = UUID()
        ledger.begin(id: active, modelID: "a", step: 21, purpose: .business, now: 2)
        _ = ledger.observe(Self.usage, id: active, provider: true)
        let value = ledger.snapshot(runID: runID, now: 3)
        XCTAssertEqual(value.requests.map(\.step), [19, 20, 21])
        XCTAssertEqual(value.latestRequest?.id, active)
        XCTAssertEqual(value.latestRequest?.state, .inFlight)
        XCTAssertEqual(value.total.reportedResponseCount, 20)
        XCTAssertEqual(value.omittedRequestCount, 18)
        XCTAssertEqual(ledger.requestClocks.count, 1)
        XCTAssertEqual(frozen.requests.map(\.id), [first])
        XCTAssertEqual(frozen.total.knownUsage?.inputTokens, 100)
    }

    func testToolUnionIsIncrementalAcrossEvictedParallelIntervals() throws {
        var ledger = BoneAgentTokenLedger(policy: try .init(maximumRequestDetails: 1, maximumToolDetails: 2))
        for index in 0..<5_000 {
            let start = Double(index * 10)
            let a = ledger.beginTool(call: Self.call("a"), step: index + 1, now: start)
            let b = ledger.beginTool(call: Self.call("b"), step: index + 1, now: start + 1)
            ledger.finishTool(a, now: start + 4)
            ledger.finishTool(b, now: start + 6)
        }
        let value = ledger.snapshot(runID: UUID(), now: 50_000)
        XCTAssertEqual(value.statistics.toolCallCount, 10_000)
        XCTAssertEqual(value.statistics.toolDurationSeconds, 45_000)
        XCTAssertEqual(value.toolWallDurationSeconds, 30_000)
        XCTAssertEqual(value.toolTimings.count, 2)
        XCTAssertEqual(value.omittedToolTimingCount, 9_998)
        XCTAssertEqual(ledger.retainedToolCount, 2)
        let active = ledger.beginTool(call: Self.call("last"), step: 5_001, now: 50_000)
        let during = ledger.snapshot(runID: value.runID, now: 50_003)
        XCTAssertEqual(during.toolTimings.count, 3)
        XCTAssertEqual(during.toolWallDurationSeconds, 30_003)
        ledger.finishTool(active, now: 50_005)
    }

    func testModelBreakdownHasExplicitBoundWithoutLosingTotals() throws {
        var ledger = BoneAgentTokenLedger(policy: try .init(maximumRequestDetails: 1, maximumModelBreakdowns: 2))
        for index in 0..<1_000 {
            let id = UUID()
            ledger.begin(id: id, modelID: "model-\(index % 10)", step: index + 1, purpose: .business, now: 0)
            _ = ledger.finish(id: id, state: .responseReceived, usage: Self.usage, now: 1)
        }
        let value = ledger.snapshot(runID: UUID(), now: 1)
        XCTAssertEqual(ledger.retainedModelCount, 2)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 100_000)
        XCTAssertEqual(value.omittedModelRequestCount, 800)
        XCTAssertTrue(value.hasModelBreakdown(for: "model-0"))
        XCTAssertEqual(value.totals(forModelID: "model-0").requestCount, 100)
        XCTAssertFalse(value.hasModelBreakdown(for: "model-9"))
        XCTAssertFalse(value.totals(forModelID: "model-9").isComplete)
    }

    func testManyLongLivedSessionAccumulatorsRetainNoFinishedRunDetails() throws {
        let start = ProcessInfo.processInfo.systemUptime
        var sessions = Array(repeating: BoneConversationStatisticsAccumulator(), count: 128)
        for round in 0..<1_000 {
            for index in sessions.indices {
                var ledger = BoneAgentTokenLedger()
                let id = UUID(), run = UUID()
                ledger.begin(id: id, modelID: "model", step: 1, purpose: .business, now: 0)
                sessions[index].observe(ledger.snapshot(runID: run, now: 0))
                _ = ledger.finish(id: id, state: .responseReceived, usage: Self.usage, now: 1)
                ledger.terminalState = .succeeded
                let final = ledger.snapshot(runID: run, now: 1)
                sessions[index].observe(final)
                sessions[index].observe(final) // A repeated final notification must not add another round.
                XCTAssertEqual(sessions[index].retainedRunCount, 0)
                if round == 999 {
                    let stats = sessions[index].statistics(isHistoryComplete: true)
                    XCTAssertEqual(stats.roundCount, 1_000)
                    XCTAssertEqual(stats.tokens.knownUsage?.inputTokens, 100_000)
                    XCTAssertEqual(stats.modelDurationSeconds, 1_000)
                }
            }
        }
        print("OBSERVATION_SESSIONS sessions=128 roundsPerSession=1000 retainedFinishedSnapshots=0 elapsedSeconds=\(ProcessInfo.processInfo.systemUptime-start)")
    }

    func testHighFrequencyUsageCoalescesButCurrentAndTerminalAreExact() async throws {
        let recorder = PerformanceRecorder()
        let reporter = BoneAgentStatusReporter(sink: .init(), tokenSink: .init { await recorder.append($0) }, clock: { 0 })
        await reporter.transition(.preparingInput)
        let id = await reporter.beginInference(step: 1, modelID: "model")
        for count in 1...10_000 {
            await reporter.telemetry(.usage(.init(inputTokens: 100, outputTokens: count, cachedInputTokens: nil, reasoningTokens: nil)), id: id)
        }
        let during = await reporter.currentTokens
        XCTAssertEqual(during?.latestRequest?.provisionalUsage?.outputTokens, 10_000)
        let before = await recorder.count
        XCTAssertEqual(before, 2)
        await reporter.transition(.reasoning) // Phase transition flushes the latest accumulated observation immediately.
        let phase = await recorder.last
        XCTAssertEqual(phase?.latestRequest?.provisionalUsage?.outputTokens, 10_000)
        await reporter.finishTokenRequest(id, state: .responseReceived, usage: .init(inputTokens: 100, outputTokens: 10_001, cachedInputTokens: nil, reasoningTokens: nil))
        await reporter.transition(.finished(.succeeded))
        let final = await recorder.last
        XCTAssertEqual(final?.total.knownUsage?.outputTokens, 10_001)
        XCTAssertEqual(final?.terminalState, .succeeded)
        let after = await recorder.count
        XCTAssertEqual(after, 5)
        print("OBSERVATION_CALLBACKS usageUpdates=10000 deliveredSnapshots=\(after)")
    }

    func testParallelNotificationOrderAndDrainedSnapshotsRemainBounded() async throws {
        let recorder = PerformanceRecorder()
        let reporter = BoneAgentStatusReporter(sink: .init(), tokenSink: .init { value in
            await Task.yield()
            await recorder.append(value)
        }, policy: try .init(maximumRequestDetails: 2, maximumToolDetails: 3, minimumTokenUpdateInterval: 0))
        await reporter.transition(.preparingInput)
        for step in 1...200 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<8 {
                    group.addTask {
                        let call = Self.call("call-\(index)", ordinal: index)
                        _ = try await reporter.withTool(call, step: step) {
                            try await reporter.measureTool(call, step: step) { await Task.yield(); return true }
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        await reporter.transition(.finished(.succeeded))
        let last = await recorder.last
        let ordered = await recorder.ordered
        XCTAssertTrue(ordered)
        XCTAssertEqual(last?.statistics.toolCallCount, 1_600)
        XCTAssertEqual(last?.toolTimings.count, 3)
        XCTAssertEqual(last?.omittedToolTimingCount, 1_597)
    }

    func testConfiguredPolicyFlowsThroughRealAgentAndSession() async throws {
        let recorder = PerformanceRecorder()
        let agent = BoneAgent(inferenceEngine: PerformanceLoopEngine(), toolRegistry: try .init(tools: [BoneAnyAgentTool(PerformanceReadTool())]),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 25, logging: .init(minimumLevel: .error),
                tokenSink: .init { await recorder.append($0) }, observationPolicy: .init(maximumRequestDetails: 2, maximumToolDetails: 3)))
        let conversation = try await agent.makeConversation(modelID: "model", bindingID: "fixture")
        _ = try await conversation.send("start")
        let value = await recorder.last
        XCTAssertEqual(value?.requests.count, 2)
        XCTAssertEqual(value?.total.requestCount, 20)
        XCTAssertEqual(value?.statistics.toolCallCount, 19)
        XCTAssertEqual(value?.toolTimings.count, 3)
        let stats = await conversation.statistics
        XCTAssertEqual(stats.stepCount, 20)
        XCTAssertEqual(stats.tokens.knownUsage?.inputTokens, 2_000)
    }

    func testManyRealConversationsCompactAccumulateAndRelease() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let retained = try await Self.exerciseSessions()
        await Task.yield()
        XCTAssertFalse(retained.contains { $0() })
        var peakBytes = 0
        #if canImport(Darwin)
        var resources = rusage()
        if getrusage(RUSAGE_SELF, &resources) == 0 { peakBytes = Int(resources.ru_maxrss) }
        #endif
        print("OBSERVATION_REAL_SESSIONS sessions=64 roundsPerSession=100 released=64 peakProcessBytes=\(peakBytes) elapsedSeconds=\(ProcessInfo.processInfo.systemUptime-start)")
    }

    func testCompletedSessionAndAgentAreReleased() async throws {
        let isRetained = try await Self.makeTemporarySession()
        await Task.yield()
        XCTAssertFalse(isRetained(), "Observation callbacks must not keep completed sessions or Agents alive")
    }

    func testDurationOverflowRemainsUnknownAfterEviction() throws {
        var ledger = BoneAgentTokenLedger(policy: try .init(maximumRequestDetails: 1))
        for step in 1...2 {
            let id = UUID()
            let end = Double.greatestFiniteMagnitude * 0.75
            ledger.begin(id: id, modelID: "model", step: step, purpose: .business, now: 0)
            ledger.requestClocks[id]?.observe(.requestStarted(liveTiming: true), now: 0)
            ledger.requestClocks[id]?.observe(.firstOutputToken, now: 1)
            ledger.requestClocks[id]?.observe(.responseFinished, now: end)
            _ = ledger.finish(id: id, state: .responseReceived, usage: Self.usage, now: end)
        }
        let value = ledger.snapshot(runID: UUID(), now: 1)
        XCTAssertEqual(value.requests.count, 1)
        XCTAssertNil(value.statistics.modelDurationSeconds)
        XCTAssertNil(value.statistics.outputTokensPerSecond)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 200)
    }

    func testPolicyRejectsUnboundedOrInvalidLimits() {
        for size in [0, -1, 1_025, Int.max] {
            XCTAssertThrowsError(try BoneAgentObservationPolicy(maximumRequestDetails: size))
        }
        for interval in [Double.nan, .infinity, -1, 61] {
            XCTAssertThrowsError(try BoneAgentObservationPolicy(maximumRequestDetails: 1, minimumTokenUpdateInterval: interval))
        }
        XCTAssertThrowsError(try BoneAgentObservationPolicy(maximumRequestDetails: 1, maximumModelBreakdowns: Int.max))
        XCTAssertThrowsError(try BoneAgentObservationPolicy(maximumRequestDetails: 1, maximumToolDetails: Int.max))
    }

    private static let usage = BoneInferenceUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: 3, reasoningTokens: nil)
    private static func call(_ id: String, ordinal: Int = 0) -> BoneInferenceToolCall {
        .init(id: id, toolID: "tool", arguments: Data("{}".utf8), ordinal: ordinal)
    }
    private static func makeTemporarySession() async throws -> @Sendable () -> Bool {
        let agent = try BoneAgentBuilder(inferenceEngine: PerformanceLoopEngine(maximum: 1)).build()
        let conversation = try await agent.makeConversation(modelID: "model", bindingID: "fixture")
        _ = try await conversation.send("one")
        return { [weak agent, weak conversation] in agent != nil || conversation != nil }
    }
    private static func exerciseSessions() async throws -> [@Sendable () -> Bool] {
        let budget = try BoneContextWindowBudget(contextWindowTokens: 192, maximumOutputTokens: 16, source: .host)
        var sessions: [BoneAgentConversation] = []
        for _ in 0..<64 {
            let agent = try BoneAgentBuilder(inferenceEngine: PerformanceLoopEngine(maximum: 1))
                .withConfiguration(.init(maximumSteps: 1, logging: .init(minimumLevel: .error),
                    contextManagement: .init(budgetProvider: { _ in budget }, protocolReserveTokens: 0, safetyMarginTokens: 0))).build()
            sessions.append(try await agent.makeConversation(modelID: "model", bindingID: "fixture"))
        }
        for _ in 0..<100 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for session in sessions { group.addTask { _ = try await session.send("continue") } }
                try await group.waitForAll()
            }
        }
        for session in sessions {
            let stats = await session.statistics
            XCTAssertEqual(stats.roundCount, 100)
            XCTAssertEqual(stats.stepCount, 100)
            XCTAssertEqual(stats.tokens.knownUsage?.inputTokens, 10_000)
            let data = try await session.exportPrivateState()
            XCTAssertLessThan(data.count, 8_192)
        }
        return sessions.map { session in { [weak session] in session != nil } }
    }
}

private actor PerformanceRecorder {
    var last: BoneAgentTokenSnapshot?
    var count = 0
    var ordered = true
    func append(_ value: BoneAgentTokenSnapshot) {
        if let last, last.runID == value.runID { ordered = ordered && last.sequence < value.sequence }
        last = value; count += 1
    }
}
private actor PerformanceLoopEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let maximum: Int
    var calls = 0
    init(maximum: Int = 20) { self.maximum = maximum }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        calls += 1
        let usage = BoneInferenceUsage(inputTokens: 100, outputTokens: 20, cachedInputTokens: nil, reasoningTokens: nil)
        if calls >= maximum { return .finish(.init(text: "done", usage: usage)) }
        return .assistantTurn(turn: try .init(content: [.toolCall(.init(id: "c\(calls)", toolID: "performance.read", arguments: Data("{}".utf8)))]),
            finishReason: .toolCalls, usage: usage, refusal: nil, providerContinuation: nil)
    }
}
private struct PerformanceReadTool: BoneAgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    typealias Context = BoneAgentEmptyContext
    static var definition: BoneAgentToolDefinition {
        .init(id: "performance.read", version: "1", title: "Read", summary: "Fixture",
              wireName: "performance_read", schemaVersion: 1,
              inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    }
    func execute(input: Input, context: Context) async throws -> Output { "ok" }
}
