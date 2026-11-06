import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class AgentTokenStatisticsTests: XCTestCase {
    private func usage(_ input: Int = 100, _ output: Int = 20, cached: Int? = nil) -> BoneInferenceUsage {
        .init(inputTokens: input, outputTokens: output, cachedInputTokens: cached, reasoningTokens: nil)
    }
    private func agent(_ engine: any BoneInferenceEngine, log: TokenLog, clock: TokenClock = .init(),
                       policy: BoneContextManagementConfiguration? = nil, tools: [BoneAnyAgentTool] = [],
                       mode: BoneAgentInferenceMode = .nonStreaming) throws -> BoneAgent {
        try .init(inferenceEngine: engine, toolRegistry: .init(tools: tools), toolContext: BoneAgentEmptyContext(),
            configuration: .init(maximumSteps: 6, inferenceMode: mode, contextManagement: policy,
                tokenSink: .init { await log.append($0) }), monotonicClock: { clock.now() })
    }
    private var request: BoneInferenceRequest { .init(modelID: "model", messages: [.init(role: .user, content: "private-input")]) }
    private func final(_ log: TokenLog) async throws -> BoneAgentTokenSnapshot {
        let values = await log.values
        return try XCTUnwrap(values.last)
    }

    func testCumulativeReportsReplaceAndFinalCommitsOnce() async throws {
        let log = TokenLog(), clock = TokenClock()
        let reporter = BoneAgentStatusReporter(sink: .init(), tokenSink: .init { await log.append($0) }, clock: { clock.now() },
            policy: try .init(maximumRequestDetails: 64, minimumTokenUpdateInterval: 0))
        await reporter.transition(.preparingInput)
        let id = await reporter.beginInference(step: 1, modelID: "model")
        await reporter.telemetry(.usage(usage(100, 3)), id: id)
        await reporter.telemetry(.usage(usage(100, 8)), id: id)
        await reporter.telemetry(.usage(usage(100, 8)), id: id)
        await reporter.streamUsage(usage(100, 3), id: id) // buffered event consumer must not regress producer observation
        let partial = try await final(log)
        XCTAssertEqual(partial.latestRequest?.provisionalUsage?.outputTokens, 8)
        XCTAssertNil(partial.total.knownUsage)
        await reporter.finishTokenRequest(id, state: .responseReceived, usage: usage(100, 10))
        await reporter.finishTokenRequest(id, state: .responseReceived, usage: usage(999, 999))
        await reporter.telemetry(.usage(usage(999, 999)), id: id)
        await reporter.transition(.finished(.succeeded))
        let value = try await final(log)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 100)
        XCTAssertEqual(value.total.knownUsage?.outputTokens, 10)
        XCTAssertEqual(value.requests.count, 1)
        XCTAssertTrue(value.total.isComplete)
        let values = await log.values
        XCTAssertEqual(values.filter { $0.latestRequest?.provisionalUsage?.outputTokens == 8 && $0.latestRequest?.state == .inFlight }.count, 1)
    }

    func testMissingAndInterruptedUsageRemainUnknown() async throws {
        let log = TokenLog()
        let r = BoneAgentStatusReporter(sink: .init(), tokenSink: .init { await log.append($0) })
        await r.transition(.preparingInput)
        let one = await r.beginInference(step: 1, modelID: "model")
        await r.finishTokenRequest(one, state: .responseReceived, usage: usage(cached: 8))
        let two = await r.beginInference(step: 2, modelID: "model")
        await r.finishTokenRequest(two, state: .responseReceived, usage: nil)
        let three = await r.beginInference(step: 3, modelID: "model")
        await r.telemetry(.usage(usage(50, 4)), id: three)
        await r.finishTokenRequest(three, state: .cancelled, usage: nil)
        await r.transition(.finished(.cancelled))
        let value = try await final(log)
        XCTAssertEqual(value.total.requestCount, 3)
        XCTAssertEqual(value.total.reportedResponseCount, 1)
        XCTAssertEqual(value.total.unreportedResponseCount, 1)
        XCTAssertEqual(value.total.unresolvedRequestCount, 1)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 100)
        XCTAssertEqual(value.requests.last?.provisionalUsage?.outputTokens, 4)
        XCTAssertNil(value.requests.last?.finalUsage)
        XCTAssertFalse(value.total.isComplete)
    }

    func testOverflowAndOptionalCoverageAreExplicit() async throws {
        var ledger = BoneAgentTokenLedger()
        for (index, report) in [usage(Int.max, Int.max, cached: 9), usage(1, 1)].enumerated() {
            let id = UUID()
            ledger.begin(id: id, modelID: "model", step: index + 1, purpose: .business, now: 0)
            XCTAssertTrue(ledger.finish(id: id, state: .responseReceived, usage: report, now: 1))
        }
        let totals = ledger.snapshot(runID: UUID(), now: 1).total
        XCTAssertTrue(totals.overflowed)
        XCTAssertFalse(totals.isComplete)
        XCTAssertEqual(totals.knownUsage?.outputTokens, Int.max)
        XCTAssertNil(totals.knownUsage?.cachedInputTokens)
    }

    func testInvalidUsageCannotPoisonObservation() async throws {
        var ledger = BoneAgentTokenLedger()
        let id = UUID()
        ledger.begin(id: id, modelID: "model", step: 1, purpose: .business, now: 0)
        XCTAssertFalse(ledger.observe(usage(-1, 8), id: id, provider: true))
        XCTAssertTrue(ledger.observe(usage(100, 8), id: id, provider: false))
        XCTAssertTrue(ledger.finish(id: id, state: .responseReceived, usage: usage(-1, 9), now: 1))
        let value = ledger.snapshot(runID: UUID(), now: 1)
        XCTAssertNil(value.total.knownUsage)
        XCTAssertEqual(value.total.unreportedResponseCount, 1)
    }

    func testPlainAndBufferedAgentExposeFinalUsageWithoutFabricatingTTFT() async throws {
        for buffered in [false, true] {
            let log = TokenLog(), clock = TokenClock()
            let engine = TimedTokenEngine(clock: clock, reports: [usage()], live: false)
            let configured = try agent(engine, log: log, clock: clock,
                mode: buffered ? .bufferedStreaming(.init(totalTimeout: 10)) : .nonStreaming)
            _ = try await configured.run(request: request)
            let value = try await final(log)
            XCTAssertEqual(value.total.knownUsage, usage())
            XCTAssertEqual(value.statistics.modelDurationSeconds, 6)
            XCTAssertNil(value.statistics.averageTimeToFirstTokenSeconds)
            XCTAssertNil(value.statistics.outputTokensPerSecond)
            XCTAssertEqual(value.context?.stage, .unmanaged)
            XCTAssertGreaterThan(value.context?.inputTokens ?? 0, 0)
            XCTAssertNil(value.context?.availableInputTokens)
            XCTAssertNil(value.context?.compactionTriggerTokens)
            let current = await configured.currentTokens
            XCTAssertEqual(current, value)
        }
    }

    func testActualAgentMeasuresTTFTAndWeightedTPSFromTelemetry() async throws {
        let log = TokenLog(), clock = TokenClock()
        let configured = try agent(TimedTokenEngine(clock: clock, reports: [usage(100, 80)], live: true), log: log, clock: clock)
        _ = try await configured.run(request: request)
        let value = try await final(log)
        XCTAssertEqual(value.statistics.averageTimeToFirstTokenSeconds, 2)
        XCTAssertEqual(value.statistics.outputTokensPerSecond, 20)
        XCTAssertEqual(value.statistics.timeToFirstTokenSampleCount, 1)
        XCTAssertEqual(value.latestRequest?.outputDurationSeconds, 4)
        XCTAssertEqual(value.latestRequest?.durationSeconds, 6)
    }

    func testStreamingUsageFallbackAndCancelledStreamRetainLastSnapshot() async throws {
        for fails in [false, true] {
            let log = TokenLog()
            let configured = try agent(TokenEventEngine(fails: fails), log: log)
            var events: [BoneAgentStreamEvent] = []
            do {
                for try await event in try await configured.runEvents(request: request, options: .init(totalTimeout: 10)) { events.append(event) }
                XCTAssertFalse(fails)
            } catch { XCTAssertTrue(fails) }
            let value = try await final(log)
            XCTAssertEqual(value.latestRequest?.provisionalUsage?.outputTokens, 8)
            XCTAssertEqual(value.total.knownUsage?.outputTokens, fails ? nil : 10)
            XCTAssertEqual(value.latestRequest?.state, fails ? .failed : .responseReceived)
            XCTAssertTrue(events.contains { if case .usage = $0 { return true }; return false })
        }
    }

    func testContextThresholdsMatchCompactionAndIncludeImages() async throws {
        let log = TokenLog()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 2_000, maximumOutputTokens: 200, source: .host)
        let policy = try BoneContextManagementConfiguration(protocolReserveTokens: 0, safetyMarginTokens: 100)
        let engine = TokenImageEngine(budget: budget)
        let old = try image("old", width: 900), new = try image("new", width: 500)
        let configured = try agent(engine, log: log, policy: policy)
        _ = try await configured.run(request: .init(modelID: "model", messages: [
            .user(content: [.image(old)]), .init(role: .assistant, content: "old"), .user(content: [.image(new)])],
            generationOptions: .init(maximumOutputTokens: 200)))
        let values = await log.values
        let before = try XCTUnwrap(values.compactMap(\.context).first { $0.stage == .beforeCompaction })
        let after = try XCTUnwrap(values.last?.context)
        XCTAssertEqual(before.availableInputTokens, 1_572)
        XCTAssertEqual(before.reservedOutputTokens, 200)
        XCTAssertEqual(before.compactionTriggerTokens, 1_336)
        XCTAssertEqual(before.compactionTargetTokens, 1_021)
        XCTAssertEqual(before.imageCount, 2)
        XCTAssertEqual(after.imageCount, 1)
        XCTAssertEqual(after.inputTokensBeforeCompaction, before.inputTokens)
        XCTAssertEqual(after.stage, .ready)
        XCTAssertLessThan(after.inputTokens!, before.inputTokens!)
        XCTAssertEqual(after.remainingInputTokens, 1_572 - after.inputTokens!)
        XCTAssertEqual(after.tokensUntilCompaction, 1_336 - after.inputTokens!)
        XCTAssertEqual(after.revision, 1)
    }

    func testBudgetRejectionPublishedBeforeAnyModelInvocation() async throws {
        let log = TokenLog()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let engine = BoneScriptedInferenceEngine(script: [])
        let configured = try agent(engine, log: log, policy: .init(budgetProvider: { _ in budget }, protocolReserveTokens: 0, safetyMarginTokens: 0))
        do { _ = try await configured.run(modelID: "model", messages: [.init(role: .user, content: String(repeating: "x", count: 3000))]); XCTFail("Over budget") }
        catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
        let value = try await final(log)
        XCTAssertEqual(value.context?.stage, .rejected)
        XCTAssertGreaterThan(value.context?.utilization ?? 0, 1)
        XCTAssertEqual(value.statistics.stepCount, 0)
        XCTAssertEqual(value.total.requestCount, 0)
    }

    func testSummaryUsageSeparateAndRetainedWhenSummaryRejected() async throws {
        for rejected in [false, true] {
            let log = TokenLog()
            let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
            let summary = BoneScriptedInferenceEngine(script: [.finish(.init(text: rejected ? "" : "old task done", usage: usage(900, 15)))])
            let binding = try BoneInferenceEngineContextSummarizer(engine: summary, modelID: "summarizer", budget: .init(contextWindowTokens: 16_384, source: .host))
            let business = BoneScriptedInferenceEngine(script: [.finish(.init(text: "done", usage: usage(80, 8)))])
            let configured = try agent(business, log: log, policy: .init(budgetProvider: { _ in budget }, summarizer: binding, protocolReserveTokens: 0, safetyMarginTokens: 0))
            _ = try await configured.run(modelID: "model", messages: [.init(role: .user, content: String(repeating: "old data ", count: 400)), .init(role: .user, content: "current")])
            let value = try await final(log)
            XCTAssertEqual(value.business.knownUsage?.inputTokens, 80)
            XCTAssertEqual(value.summaries.knownUsage?.inputTokens, 900)
            XCTAssertEqual(value.total.knownUsage?.outputTokens, 23)
            XCTAssertEqual(value.totals(forModelID: "summarizer").knownUsage?.outputTokens, 15)
            XCTAssertEqual(value.statistics.stepCount, 1)
            XCTAssertEqual(value.statistics.summaryCallCount, 1)
            XCTAssertEqual(value.summaryContext?.modelID, "summarizer")
            XCTAssertEqual(value.context?.modelID, "model")
        }
    }

    func testConversationThreeRoundsAndDeduplicatedSessionStatistics() async throws {
        let log = TokenLog(), clock = TokenClock()
        let configured = try agent(TimedTokenEngine(clock: clock, reports: [usage(), usage(), usage()], live: true), log: log, clock: clock)
        let conversation = try await configured.makeConversation(modelID: "model", bindingID: "local")
        for value in ["one", "two", "three"] { _ = try await conversation.send(value) }
        let stats = await conversation.statistics
        XCTAssertEqual(stats.roundCount, 3)
        XCTAssertEqual(stats.stepCount, 3)
        XCTAssertEqual(stats.modelDurationSeconds, 18)
        XCTAssertEqual(stats.averageTimeToFirstTokenSeconds, 2)
        XCTAssertEqual(stats.tokens.knownUsage?.outputTokens, 60)
        let values = await log.values
        let combined = BoneAgentStatistics(snapshots: values + values.reversed())
        XCTAssertEqual(combined, stats)
        let data = try await conversation.exportPrivateState()
        let id = await conversation.id
        let restored = try await configured.restoreConversation(privateState: data, modelID: "model", bindingID: "local", expectedID: id, expectedRevision: 3)
        let partial = await restored.statistics
        XCTAssertFalse(partial.isHistoryComplete)
        XCTAssertEqual(partial.roundCount, 0)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("durationSeconds"))
    }

    func testClockErrorsAndSingleChunkDoNotProduceInfinityOrFakeTiming() throws {
        for end in [0.0, -1, .nan, .infinity] {
            var ledger = BoneAgentTokenLedger()
            let id = UUID()
            ledger.begin(id: id, modelID: "model", step: 1, purpose: .business, now: 1)
            ledger.requestClocks[id]?.observe(.requestStarted(liveTiming: true), now: 1)
            ledger.requestClocks[id]?.observe(.firstOutputToken, now: 1)
            ledger.requestClocks[id]?.observe(.responseFinished, now: end)
            _ = ledger.finish(id: id, state: .responseReceived, usage: usage(), now: end)
            XCTAssertNil(ledger.snapshot(runID: UUID(), now: end).statistics.outputTokensPerSecond)
        }
    }

    func testThroughputIsWeightedNotAverageOfRates() throws {
        var ledger = BoneAgentTokenLedger()
        for (duration, output) in [(2.0, 100), (10.0, 100)] {
            let id = UUID()
            ledger.begin(id: id, modelID: "model", step: 1, purpose: .business, now: 0)
            ledger.requestClocks[id]?.observe(.requestStarted(liveTiming: true), now: 0)
            ledger.requestClocks[id]?.observe(.firstOutputToken, now: 1)
            ledger.requestClocks[id]?.observe(.responseFinished, now: duration + 1)
            _ = ledger.finish(id: id, state: .responseReceived, usage: usage(10, output), now: duration + 1)
        }
        let stats = ledger.snapshot(runID: UUID(), now: 11).statistics
        XCTAssertEqual(stats.outputTokensPerSecond!, 200.0 / 12.0, accuracy: 0.0001)
        XCTAssertEqual(stats.throughputSampleCount, 2)
    }

    func testToolTimingSumAndUnionDoNotConfuseParallelWork() async throws {
        let log = TokenLog(), clock = TokenClock()
        let reporter = BoneAgentStatusReporter(sink: .init(), tokenSink: .init { await log.append($0) }, clock: { clock.now() })
        let first = TokenGate(), second = TokenGate(), beganFirst = TokenGate(), beganSecond = TokenGate()
        await reporter.transition(.preparingInput)
        let a = BoneInferenceToolCall(id: "a", toolID: "tool", arguments: Data("{}".utf8), ordinal: 0)
        let b = BoneInferenceToolCall(id: "b", toolID: "tool", arguments: Data("{}".utf8), ordinal: 1)
        let taskA = Task { try await reporter.withTool(a, step: 1) {
            try await reporter.measureTool(a, step: 1) { await beganFirst.open(); await first.wait(); return 1 }
        } }
        await beganFirst.wait()
        clock.set(2)
        let taskB = Task { try await reporter.withTool(b, step: 1) {
            try await reporter.measureTool(b, step: 1) { await beganSecond.open(); await second.wait(); return 2 }
        } }
        await beganSecond.wait()
        clock.set(5); await first.open(); _ = try await taskA.value
        clock.set(8); await second.open(); _ = try await taskB.value
        await reporter.transition(.finished(.succeeded))
        let value = try await final(log)
        XCTAssertEqual(value.statistics.toolCallCount, 2)
        XCTAssertEqual(value.statistics.toolDurationSeconds, 11)
        XCTAssertEqual(value.statistics.toolWallDurationSeconds, 8)
    }

    func testRealToolLoopCountsStepsAndSingleExecution() async throws {
        let log = TokenLog(), clock = TokenClock()
        let call = BoneInferenceToolCall(id: "call", toolID: TimedTokenTool.definition.id, arguments: Data("{}".utf8))
        let engine = BoneScriptedInferenceEngine(script: [
            .assistantTurn(turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls, usage: usage(), refusal: nil, providerContinuation: nil),
            .finish(.init(text: "done", usage: usage()))])
        let configured = try agent(engine, log: log, clock: clock, tools: [BoneAnyAgentTool(TimedTokenTool(clock: clock))])
        _ = try await configured.run(request: request)
        let value = try await final(log)
        XCTAssertEqual(value.statistics.roundCount, 1)
        XCTAssertEqual(value.statistics.stepCount, 2)
        XCTAssertEqual(value.statistics.toolCallCount, 1)
        XCTAssertEqual(value.statistics.toolDurationSeconds, 7)
        XCTAssertEqual(value.total.knownUsage?.inputTokens, 200)
    }

    func testTokenObserverCanReadSnapshotAndCancellationRetainsUsage() async throws {
        let log = TokenLog(), holder = TokenAgentHolder()
        let engine = BoneScriptedInferenceEngine(script: [.finish(.init(text: "private-output", usage: usage()))])
        let configured = try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(.init(maximumSteps: 1, tokenSink: .init { value in
            await log.append(value)
            if let agent = await holder.agent {
                let current = await agent.currentTokens
                XCTAssertEqual(current?.runID, value.runID)
            }
            if value.latestRequest?.state == .responseReceived && value.terminalState == nil {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        })).build()
        await holder.set(configured)
        let runRequest = request
        let task = Task { try await configured.run(request: runRequest) }
        do { _ = try await task.value; XCTFail("Expected cancellation after response") } catch { XCTAssertTrue(error is CancellationError) }
        let value = try await final(log)
        XCTAssertEqual(value.terminalState, .cancelled)
        XCTAssertEqual(value.total.knownUsage?.outputTokens, 20)
        let values = await log.values
        XCTAssertFalse(String(describing: values).contains("private-output"))
        XCTAssertFalse(String(describing: values).contains("private-input"))
    }

    func testConversationQueryRefreshesActiveDurationWithoutNewEvents() async throws {
        let log = TokenLog(), clock = TokenClock(), entered = TokenGate(), release = TokenGate()
        let configured = try agent(PausedTokenEngine(entered: entered, release: release), log: log, clock: clock)
        let conversation = try await configured.makeConversation(modelID: "model", bindingID: "local")
        let task = Task { try await conversation.send("current") }
        await entered.wait()
        let before = await configured.currentTokens
        clock.set(9)
        let stats = await conversation.statistics
        let refreshed = await configured.currentTokens
        XCTAssertEqual(stats.modelDurationSeconds, 9)
        XCTAssertEqual(stats.roundCount, 1)
        XCTAssertEqual(refreshed?.sequence, before?.sequence)
        XCTAssertEqual(refreshed?.requests.first?.state, .inFlight)
        await release.open()
        _ = try await task.value
    }

    func testTokenizerObservationReusesPlannerMeasurement() async throws {
        let log = TokenLog(), engine = CountingTokenEngine()
        let configured = try agent(engine, log: log, policy: .init())
        _ = try await configured.run(request: request)
        let snapshot = try await final(log)
        XCTAssertEqual(snapshot.context?.source, .tokenizer)
        XCTAssertEqual(snapshot.context?.inputTokens, 123)
        let calls = await engine.countCalls
        XCTAssertEqual(calls, 1)
    }

    func testObserverDelayExcludedFromToolBodyDuration() async throws {
        let clock = TokenClock(), log = TokenLog()
        let reporter = BoneAgentStatusReporter(sink: .init { value in
            if value.phase == .executingTools { clock.set(clock.now() + 50) }
        }, tokenSink: .init { await log.append($0) }, clock: { clock.now() })
        await reporter.transition(.preparingInput)
        let call = BoneInferenceToolCall(id: "call", toolID: "tool", arguments: Data("{}".utf8))
        _ = try await reporter.withTool(call, step: 1) {
            try await reporter.measureTool(call, step: 1) { clock.set(clock.now() + 3); return true }
        }
        await reporter.transition(.finished(.succeeded))
        let snapshot = try await final(log)
        XCTAssertEqual(snapshot.statistics.toolDurationSeconds, 3)
        XCTAssertEqual(snapshot.statistics.toolCallCount, 1)
    }

    func testTransportStartDoesNotAddAnObserverPauseToTTFT() async throws {
        let clock = TokenClock(), log = TokenLog()
        let reporter = BoneAgentStatusReporter(sink: .init { _ in clock.set(clock.now() + 10) },
            tokenSink: .init { await log.append($0) }, clock: { clock.now() })
        await reporter.transition(.preparingInput)
        let id = await reporter.beginInference(step: 1, modelID: "model")
        let start = clock.now()
        await reporter.telemetry(.requestStarted(liveTiming: true), id: id)
        XCTAssertEqual(clock.now(), start)
        clock.set(start + 2)
        await reporter.telemetry(.firstOutputToken, id: id)
        let snapshot = try await final(log)
        XCTAssertEqual(snapshot.latestRequest?.timeToFirstTokenSeconds, 2)
    }

    func testCancellationWhileAwaitingStreamIsNotReportedAsFailure() async throws {
        let log = TokenLog(), received = TokenGate(), ended = TokenGate()
        let state = HeldTokenStream()
        let configured = try BoneAgentBuilder(inferenceEngine: HeldTokenEngine(state: state)).withConfiguration(.init(maximumSteps: 1,
            tokenSink: .init { value in
                await log.append(value)
                if value.terminalState != nil { await ended.open() }
            })).build()
        let runRequest = request
        let task = Task {
            do {
                for try await event in try await configured.runEvents(request: runRequest, options: .init(totalTimeout: 10)) {
                    if case .usage = event { await received.open() }
                }
            } catch { }
        }
        await received.wait()
        task.cancel()
        await task.value
        await ended.wait()
        let snapshot = try await final(log)
        XCTAssertEqual(snapshot.terminalState, .cancelled)
        XCTAssertEqual(snapshot.latestRequest?.state, .cancelled)
        XCTAssertEqual(snapshot.latestRequest?.provisionalUsage?.outputTokens, 3)
        XCTAssertNil(snapshot.total.knownUsage)
        await state.finish()
    }

    private func image(_ id: String, width: Int) throws -> BoneInferenceImageInput {
        let metadata = try BoneInferenceImageMetadata(format: .png, width: width, height: 1, byteCount: 3)
        return .init(reference: try BoneInferencePreparedImage(data: Data([1,2,3]), metadata: metadata).reference(id: id, version: "1"))
    }
}

private actor TokenLog { var values: [BoneAgentTokenSnapshot] = []; func append(_ value: BoneAgentTokenSnapshot) { values.append(value) } }
private final class TokenClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func set(_ value: TimeInterval) { lock.lock(); self.value = value; lock.unlock() }
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
}
private actor TokenAgentHolder { var agent: BoneAgent?; func set(_ value: BoneAgent) { agent = value } }
private actor TokenGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let old = waiters; waiters = []; old.forEach { $0.resume() } }
}
private actor TimedTokenEngine: BoneInferenceEngine, BoneInferenceBufferedStreaming {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let clock: TokenClock
    var reports: [BoneInferenceUsage]
    let live: Bool
    init(clock: TokenClock, reports: [BoneInferenceUsage], live: Bool) { self.clock = clock; self.reports = reports; self.live = live }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let start = clock.now()
        await BoneInferenceTelemetryReporting.report(.requestStarted(liveTiming: live))
        clock.set(start + 2)
        await BoneInferenceTelemetryReporting.report(.firstOutputToken)
        let report = reports.removeFirst()
        await BoneInferenceTelemetryReporting.report(.usage(.init(inputTokens: report.inputTokens, outputTokens: 1, cachedInputTokens: nil, reasoningTokens: nil)))
        clock.set(start + 6)
        await BoneInferenceTelemetryReporting.report(.responseFinished)
        return .finish(.init(text: "done", usage: report))
    }
    func inferUsingStream(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceResponse { try await infer(request: request) }
}
private struct TokenImageEngine: BoneInferenceEngine, BoneInferenceContextBudgetProviding, BoneInferenceImageTokenProviding {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .imageInput]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let budget: BoneContextWindowBudget
    func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? { budget }
    func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int { image.reference.metadata.width }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "done") }
}
private struct TokenEventEngine: BoneInferenceEngine, BoneInferenceEventStreaming {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let fails: Bool
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "unused") }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        .init { continuation in
            for output in [2, 8, 8] { continuation.yield(.usage(.init(inputTokens: 100, outputTokens: output, cachedInputTokens: nil, reasoningTokens: nil))) }
            if fails { continuation.finish(throwing: BoneInferenceTransportError.invalidResponse); return }
            continuation.yield(.completed(.init(response: .finish(.init(text: "done", usage: .init(inputTokens: 100, outputTokens: 10, cachedInputTokens: nil, reasoningTokens: nil))), reasoning: nil)))
            continuation.finish()
        }
    }
}
private struct TimedTokenTool: BoneAgentTool {
    struct Input: Codable, Sendable {}
    typealias Output = String
    typealias Context = BoneAgentEmptyContext
    let clock: TokenClock
    static var definition: BoneAgentToolDefinition { .init(id: "timed.tool", version: "1", title: "Fixture", summary: "Fixture", wireName: "timed_tool", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead) }
    func execute(input: Input, context: Context) async throws -> String { clock.set(clock.now() + 7); return "private-tool-result" }
}

private struct PausedTokenEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let entered: TokenGate
    let release: TokenGate
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        await entered.open(); await release.wait(); return .init(text: "done")
    }
}
private actor CountingTokenEngine: BoneInferenceEngine, BoneInferenceContextTokenCounting, BoneInferenceContextBudgetProviding {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    var countCalls = 0
    nonisolated func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? {
        try .init(contextWindowTokens: 4_096, maximumOutputTokens: 100, source: .runtime)
    }
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int { countCalls += 1; return 123 }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "done") }
}

private actor HeldTokenStream {
    var continuation: BoneInferenceNormalizedEventStream.Continuation?
    func install(_ value: BoneInferenceNormalizedEventStream.Continuation) {
        continuation = value
        value.yield(.usage(.init(inputTokens: 10, outputTokens: 3, cachedInputTokens: nil, reasoningTokens: nil)))
    }
    func finish() { continuation?.finish(); continuation = nil }
}
private struct HeldTokenEngine: BoneInferenceEngine, BoneInferenceEventStreaming {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let state: HeldTokenStream
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "unused") }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        .init { value in Task { await state.install(value) } }
    }
}
