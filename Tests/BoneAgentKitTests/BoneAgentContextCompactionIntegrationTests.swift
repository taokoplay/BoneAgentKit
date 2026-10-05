import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class BoneAgentContextCompactionIntegrationTests: XCTestCase {
    private let history: [BoneInferenceMessage] = [
        .init(role: .system, content: "Keep rules"),
        .init(role: .user, content: "old"),
        .init(role: .assistant, content: String(repeating: "history-private ", count: 150)),
        .init(role: .user, content: "current")
    ]
    private func policy(summarizer: (any BoneContextSummarizing)? = nil,
                        receipts: ContextReceiptRecorder? = nil) throws -> BoneContextManagementConfiguration {
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        return try .init(budgetProvider: { _ in budget }, summarizer: summarizer,
                         protocolReserveTokens: 0, safetyMarginTokens: 0,
                         maximumSummaryOutputTokens: 80, receiptSink: { await receipts?.append($0) })
    }
    private func agent(_ engine: any BoneInferenceEngine, policy: BoneContextManagementConfiguration?,
                       budget: BoneRunBudget? = nil) throws -> BoneAgent {
        BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
                  configuration: try .init(maximumSteps: 1, runBudget: budget, inferenceCostEstimator: { _ in 0 }, contextManagement: policy))
    }
    private func summary(_ engine: any BoneInferenceEngine) throws -> BoneInferenceEngineContextSummarizer {
        try .init(engine: engine, modelID: "summary-model", budget: .init(contextWindowTokens: 4_096, source: .host), costEstimator: { _ in 0 })
    }

    func testDisabledPreservesOriginalAndEnabledTrimsBeforeInference() async throws {
        for enabled in [false, true] {
            let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
            let result = try await agent(engine, policy: enabled ? policy() : nil).run(modelID: "model", messages: history)
            XCTAssertEqual(result.steps, 1)
            let awaited1 = await engine.receivedRequests().first
            let request = try XCTUnwrap(awaited1)
            XCTAssertEqual(request.messages, enabled ? [history[0], history[3]] : history)
            XCTAssertEqual(request.generationOptions.maximumOutputTokens, enabled ? 64 : nil)
        }
    }

    func testSummaryUsesExplicitModelAndNoToolsAndKeepsCurrentRequest() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
        let summaryEngine = BoneScriptedInferenceEngine(script: [.init(text: "Goal: preserve identifiers. Pending: current.")])
        let receipts = ContextReceiptRecorder()
        _ = try await agent(engine, policy: policy(summarizer: summary(summaryEngine), receipts: receipts)).run(modelID: "model", messages: history)
        let awaited2 = await engine.receivedRequests().first
        let request = try XCTUnwrap(awaited2)
        XCTAssertEqual(request.messages.first, history.first)
        XCTAssertEqual(request.messages.last, history.last)
        XCTAssertTrue(request.messages[1].content?.contains("Goal: preserve identifiers") == true)
        XCTAssertNotEqual(request.messages[1].role, .system)
        let awaited3 = await summaryEngine.receivedRequests().first
        let sent = try XCTUnwrap(awaited3)
        XCTAssertEqual(sent.modelID, "summary-model")
        XCTAssertTrue(sent.availableTools.isEmpty)
        XCTAssertNil(sent.providerContinuation)
        XCTAssertNil(sent.outputConstraint)
        XCTAssertEqual(sent.reasoningDisclosure, .hidden)
        let events = await receipts.values
        XCTAssertTrue(events.first?.usedModelSummary == true)
        let json = String(decoding: try JSONEncoder().encode(events), as: UTF8.self)
        XCTAssertFalse(json.contains("history-private"))
        XCTAssertFalse(json.contains("preserve identifiers"))
    }

    func testIncompleteSummaryFallsBackButUnknownFailureDoesNotSendBusinessRequest() async throws {
        let invalid = BoneScriptedInferenceEngine(script: [.assistantTurn(turn: try .init(content: [.text("partial")]), finishReason: .length, usage: nil, refusal: nil, providerContinuation: nil)])
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
        let receipts = ContextReceiptRecorder()
        _ = try await agent(engine, policy: policy(summarizer: summary(invalid), receipts: receipts)).run(modelID: "model", messages: history)
        let awaited4 = await receipts.values.first?.fallbackUsed == true
        XCTAssertTrue(awaited4)
        let awaited5 = await engine.receivedRequests().first?.messages
        XCTAssertEqual(awaited5, [history[0], history[3]])

        let untouched = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        do {
            _ = try await agent(untouched, policy: policy(summarizer: summary(ContextFailingEngine()))).run(modelID: "model", messages: history)
            XCTFail("unknown summary failure must stop")
        } catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
        let awaited6 = await untouched.receivedRequests().isEmpty
        XCTAssertTrue(awaited6)
    }

    func testSummaryConsumesInferenceBudgetButNotBusinessTurnBudget() async throws {
        for calls in [1, 2] {
            let summaryEngine = BoneScriptedInferenceEngine(script: [.init(text: "summary")])
            let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
            let budget = try BoneRunBudget(maximumInferenceCalls: calls, maximumToolCalls: 1, maximumInputBytes: 100_000,
                maximumOutputBytes: 100_000, maximumTurns: 1, maximumWallClockSeconds: 60,
                maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 10)
            do {
                let result = try await agent(engine, policy: policy(summarizer: summary(summaryEngine)), budget: budget).run(modelID: "model", messages: history)
                XCTAssertEqual(calls, 2); XCTAssertEqual(result.steps, 1)
            } catch { XCTAssertEqual(calls, 1); XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
            let awaited7 = await summaryEngine.receivedRequests().count
            XCTAssertEqual(awaited7, 1)
            let awaited8 = await engine.receivedRequests().count
            XCTAssertEqual(awaited8, calls - 1)
        }
    }

    func testHugeCurrentMessageFailsWithoutSendingOrDiscardingIt() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        do {
            _ = try await agent(engine, policy: policy()).run(modelID: "model", messages: [.init(role: .user, content: String(repeating: "x", count: 3_000))])
            XCTFail("mandatory input exceeds limit")
        } catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
        let awaited9 = await engine.receivedRequests().isEmpty
        XCTAssertTrue(awaited9)
    }

    func testCancelledSummaryNeverCommitsCandidateOrStartsBusinessInference() async throws {
        let blocked = ContextBlockingSummary()
        let business = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let configured = try agent(business, policy: policy(summarizer: summary(blocked)))
        let messages = history
        let task = Task { try await configured.run(modelID: "model", messages: messages) }
        await blocked.waitUntilEntered()
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sent = await business.receivedRequests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testNoSummaryCallWhenItsInputExceedsItsOwnBudget() async throws {
        let summarizer = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let binding = try BoneInferenceEngineContextSummarizer(engine: summarizer, modelID: "small",
            budget: .init(contextWindowTokens: 256, maximumOutputTokens: 32, source: .host))
        let business = BoneScriptedInferenceEngine(script: [.init(text: "done")])
        _ = try await agent(business, policy: policy(summarizer: binding)).run(modelID: "model", messages: history)
        let attempts = await summarizer.receivedRequests()
        XCTAssertTrue(attempts.isEmpty)
    }

    func testSummaryCallLimitDoesNotResetAfterCompaction() async throws {
        let summarizer = BoneScriptedInferenceEngine(script: [.init(text: "remembered")])
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summary(summarizer),
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 80, maximumSummaryCallsPerRun: 1)
        let engine = BoneScriptedInferenceEngine(script: [])
        var state = BoneContextSession()
        _ = try await state.prepare(request: .init(modelID: "model", messages: history), engine: engine, policy: policy, meter: nil, clock: { 0 })
        let again = try await state.prepare(request: .init(modelID: "model", messages: history), engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertTrue(again.receipt?.fallbackUsed == true)
        let attempts = await summarizer.receivedRequests()
        XCTAssertEqual(attempts.count, 1)
    }

    func testSummaryUsesClampedProjectionAndRejectsTinyClampLimit() async throws {
        let summarizer = BoneScriptedInferenceEngine(script: [.init(text: "safe summary")])
        let binding = try summary(summarizer)
        let engine = BoneScriptedInferenceEngine(script: [])
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let call = BoneInferenceToolCall(id: "c", toolID: "large.read", arguments: Data("{}".utf8))
        let tool = try BoneInferenceMessage.toolResult(.init(callID: "c", toolID: "large.read",
            content: .text(String(repeating: "canary-middle", count: 500)), isError: false, ordinal: 0))
        let messages: [BoneInferenceMessage] = [.init(role: .user, content: String(repeating: "old task ", count: 300)),
            .assistant(try .init(content: [.toolCall(call)])), tool, .init(role: .user, content: "current")]
        for limit in [8, 64] {
            let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: binding,
                protocolReserveTokens: 0, safetyMarginTokens: 0, toolResultPolicy: { _ in .clamp(maximumBytes: limit) })
            var state = BoneContextSession()
            if limit == 8 {
                do { _ = try await state.prepare(request: .init(modelID: "model", messages: messages), engine: engine, policy: policy, meter: nil, clock: { 0 }); XCTFail("invalid clamp") }
                catch { XCTAssertEqual(error as? BoneContextCompactionError, .invalidConfiguration) }
            } else {
                _ = try await state.prepare(request: .init(modelID: "model", messages: messages), engine: engine, policy: policy, meter: nil, clock: { 0 })
            }
        }
        let requests = await summarizer.receivedRequests()
        XCTAssertEqual(requests.count, 1)
        let payload = try XCTUnwrap(requests.first?.messages.last?.content)
        XCTAssertTrue(payload.contains("context-compacted"))
        XCTAssertFalse(payload.contains(String(repeating: "canary-middle", count: 10)))
    }

    func testSafeTelemetryAndBusinessWorkflowCountsRemainSeparate() async throws {
        let logger = ContextSafeLogger()
        let recorder = ContextObservationRecorder()
        let summaryEngine = BoneScriptedInferenceEngine(script: [.init(text: "summary-secret")])
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "answer-secret")])
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summary(summaryEngine),
            protocolReserveTokens: 0, safetyMarginTokens: 0, summaryAttemptSink: { await recorder.attempt($0) })
        let configuration = try BoneAgentConfiguration(maximumSteps: 1,
            logging: .init(isDebugEnabled: true, minimumLevel: .debug, logger: logger, includesSensitivePayloads: true), contextManagement: policy)
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: configuration, progressSink: .init { await recorder.progress($0) }, modelSnapshotSink: .init { await recorder.snapshot($0) })
        _ = try await agent.run(modelID: "model", messages: history)
        let observation = await recorder.values()
        XCTAssertEqual(observation.attempts.count, 1)
        XCTAssertEqual(observation.attempts.first?.outcome, .completed)
        XCTAssertEqual(observation.responses, 1)
        XCTAssertEqual(observation.snapshots.first?.inferenceResponseCount, 1)
        let logs = logger.values()
        XCTAssertTrue(logs.contains("context.compaction.committed"))
        for secret in ["history-private", "summary-secret", "answer-secret"] { XCTAssertFalse(logs.contains(secret)) }
    }

    func testWallClockExpiryAfterTokenPreflightPreventsInference() async throws {
        let clock = ContextTestClock()
        let engine = ContextCountingEngine(clock: clock)
        let budget = try BoneRunBudget(maximumInferenceCalls: 2, maximumToolCalls: 1, maximumInputBytes: 100_000,
            maximumOutputBytes: 100_000, maximumTurns: 1, maximumWallClockSeconds: 1,
            maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 0)
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 1, runBudget: budget, inferenceCostEstimator: { _ in 0 }, contextManagement: policy()),
            monotonicClock: { clock.now() })
        do { _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "small")]); XCTFail("expired") }
        catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
        let sends = await engine.sends
        XCTAssertEqual(sends, 0)
    }

    func testOptInCompactsOnlyCompletedOldExchangesInsideCurrentTurn() async throws {
        let budget = try BoneContextWindowBudget(contextWindowTokens: 1024, maximumOutputTokens: 64, source: .host)
        let engine = BoneScriptedInferenceEngine(script: [])
        let summaryEngine = BoneScriptedInferenceEngine(script: [.finish(.init(text: "old exchange summary",
            usage: .init(inputTokens: 100, outputTokens: 5, cachedInputTokens: nil, reasoningTokens: nil)))])
        let recorder = ContextObservationRecorder()
        var messages: [BoneInferenceMessage] = [.init(role: .system, content: "Rules"), .init(role: .user, content: "Current request")]
        for id in ["old", "recent"] {
            let call = BoneInferenceToolCall(id: id, toolID: "read", arguments: Data("{}".utf8))
            messages.append(.assistant(try .init(content: [.toolCall(call)])))
            messages.append(try .toolResult(.init(callID: id, toolID: "read", content: .text(String(repeating: "data ", count: 300)), isError: false, ordinal: 0)))
        }
        let defaultPolicy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, protocolReserveTokens: 0, safetyMarginTokens: 0)
        var untouched = BoneContextSession()
        do { _ = try await untouched.prepare(request: .init(modelID: "model", messages: messages), engine: engine, policy: defaultPolicy, meter: nil, clock: { 0 }); XCTFail("default protects entire turn") }
        catch { XCTAssertEqual(untouched.revision, 0) }
        let optIn = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summary(summaryEngine),
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 80,
            minimumRecentToolExchangeCount: 1, summaryAttemptSink: { await recorder.attempt($0) })
        var state = BoneContextSession()
        let prepared = try await state.prepare(request: .init(modelID: "model", messages: messages), engine: engine, policy: optIn, meter: nil, clock: { 0 })
        XCTAssertEqual(prepared.history, Array(messages.prefix(2)) + messages.suffix(2))
        XCTAssertEqual(prepared.receipt?.removedToolExchangeCount, 1)
        XCTAssertEqual(prepared.receipt?.removedTurnCount, 0)
        XCTAssertEqual(prepared.receipt?.removedMessageCount, 2)
        XCTAssertTrue(prepared.receipt?.usedModelSummary == true)
        XCTAssertNoThrow(try BoneContextTurn.split(prepared.history))
        let observations = await recorder.values()
        XCTAssertEqual(observations.attempts.first?.usage?.inputTokens, 100)
    }

    func testLongToolRunContinuesAfterCompactingCompletedExchanges() async throws {
        let calls = try ["a", "b"].map { id in
            BoneInferenceResponse.assistantTurn(turn: try .init(content: [.toolCall(.init(id: id, toolID: "large.read", arguments: Data("{}".utf8)))]),
                finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil)
        }
        let engine = BoneScriptedInferenceEngine(script: calls + [.init(text: "finished")])
        let summaryEngine = BoneScriptedInferenceEngine(script: [.init(text: "first read completed")])
        let budget = try BoneContextWindowBudget(contextWindowTokens: 1024, maximumOutputTokens: 64, source: .host)
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summary(summaryEngine),
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 80, minimumRecentToolExchangeCount: 1)
        let subject = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: [BoneAnyAgentTool(ContextLargeReadTool())]),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 3, contextManagement: policy))
        let result = try await subject.run(modelID: "model", messages: [.init(role: .user, content: "Current request")])
        XCTAssertEqual(result.steps, 3)
        let requests = await engine.receivedRequests()
        let last = try XCTUnwrap(requests.last)
        XCTAssertTrue(last.messages.contains { $0.content == "Current request" })
        XCTAssertEqual(last.messages.compactMap { $0.assistantTurn?.toolCalls.first?.id }, ["b"])
        let summaries = await summaryEngine.receivedRequests()
        XCTAssertEqual(summaries.count, 1)
    }

    func testContextFailureSinkExplainsOversizedInputWithoutBody() async throws {
        let recorder = ContextDiagnosticRecorder()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 256, maximumOutputTokens: 32, source: .host)
        let config = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, protocolReserveTokens: 0,
            safetyMarginTokens: 0, failureSink: { await recorder.add($0) })
        let engine = BoneScriptedInferenceEngine(script: [])
        do { _ = try await agent(engine, policy: config).run(modelID: "model", messages: [.init(role: .user, content: String(repeating: "private", count: 500))]); XCTFail("too large") }
        catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
        let diagnostics = await recorder.values
        XCTAssertEqual(diagnostics, [.inputExceedsBudget])
    }

    func testReusesSummaryWithoutAddingMultipleSummaryMessages() async throws {
        let engine = BoneScriptedInferenceEngine(script: [])
        let summaryEngine = BoneScriptedInferenceEngine(script: [.init(text: "remembered")])
        let policy = try policy(summarizer: summary(summaryEngine))
        var state = BoneContextSession()
        let first = try await state.prepare(request: .init(modelID: "model", messages: history), engine: engine, policy: policy, meter: nil, clock: { 0 })
        let second = try await state.prepare(request: .init(modelID: "model", messages: first.history), engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertEqual(first.request.messages, second.request.messages)
        XCTAssertNil(second.receipt)
        let awaited10 = await summaryEngine.receivedRequests().count
        XCTAssertEqual(awaited10, 1)
    }
}

private actor ContextReceiptRecorder {
    var values: [BoneContextCompactionReceipt] = []
    func append(_ receipt: BoneContextCompactionReceipt) { values.append(receipt) }
}
private struct ContextFailingEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { throw BoneInferenceTransportError.httpStatus(503) }
}

private actor ContextBlockingSummary: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        entered = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return .init(text: "late")
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class ContextSafeLogger: BoneAgentLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {
        lock.lock(); defer { lock.unlock() }
        lines.append(message() + String(describing: context?.values))
    }
    func values() -> String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
}
private actor ContextObservationRecorder {
    var attempts: [BoneContextSummaryAttempt] = []
    var snapshots: [BoneAgentRunModelSnapshot] = []
    var responses = 0
    func attempt(_ value: BoneContextSummaryAttempt) { attempts.append(value) }
    func snapshot(_ value: BoneAgentRunModelSnapshot) { snapshots.append(value) }
    func progress(_ value: BoneAgentProgress) { if case .inferenceResponsePrepared = value { responses += 1 } }
    func values() -> (attempts: [BoneContextSummaryAttempt], snapshots: [BoneAgentRunModelSnapshot], responses: Int) { (attempts, snapshots, responses) }
}

private final class ContextTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func expire() { lock.lock(); defer { lock.unlock() }; value = 2 }
}
private actor ContextCountingEngine: BoneInferenceEngine, BoneInferenceContextTokenCounting {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let clock: ContextTestClock
    var sends = 0
    init(clock: ContextTestClock) { self.clock = clock }
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int { clock.expire(); return 10 }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { sends += 1; return .init(text: "unexpected") }
}

private actor ContextDiagnosticRecorder {
    var values: [BoneContextFailureDiagnostic] = []
    func add(_ value: BoneContextFailureDiagnostic) { values.append(value) }
}

private struct ContextLargeReadTool: BoneAgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable { let value: String }
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(id: "large.read", version: "1", title: "Large Read", summary: "Read fixture",
        wireName: "large_read", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    func execute(input: Input, context: Context) async throws -> Output { .init(value: String(repeating: "data ", count: 300)) }
}
