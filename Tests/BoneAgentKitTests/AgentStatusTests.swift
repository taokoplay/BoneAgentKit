import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class AgentStatusTests: XCTestCase {
    private var request: BoneInferenceRequest {
        .init(modelID: "fixture", messages: [.init(role: .user, content: "private-prompt")])
    }
    private func makeAgent(_ engine: any BoneInferenceEngine, recorder: StatusRecorder,
                           context: BoneContextManagementConfiguration? = nil,
                           mode: BoneAgentInferenceMode = .nonStreaming,
                           tools: [BoneAnyAgentTool] = [], strategy: BoneToolFailureStrategy = .failFast) throws -> BoneAgent {
        try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(.init(maximumSteps: 4,
            toolSchedulingMode: .boundedParallel(maximumConcurrency: 2), toolFailureStrategy: strategy,
            inferenceMode: mode, contextManagement: context, statusSink: .init { await recorder.receive($0) }))
            .withToolsForStatusTest(tools).build()
    }
    private func assertRun(_ values: [BoneAgentStatus], terminal: BoneAgentRunTerminalState = .succeeded,
                           file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(values.first?.phase, .preparingInput, file: file, line: line)
        XCTAssertEqual(values.last?.phase, .finished(terminal), file: file, line: line)
        XCTAssertEqual(values.filter(\.isTerminal).count, 1, file: file, line: line)
        XCTAssertEqual(values.map(\.sequence), values.indices.map { UInt64($0 + 1) }, file: file, line: line)
        XCTAssertEqual(Set(values.map(\.runID)).count, 1, file: file, line: line)
        XCTAssertTrue(values.last?.activeTools.isEmpty == true, file: file, line: line)
        for secret in ["private-prompt", "private-answer", "private-reasoning", "private-argument"] {
            XCTAssertFalse(String(describing: values).contains(secret), file: file, line: line)
        }
    }

    func testPlainRunReportsStagesAndSnapshotWithoutInventingReasoning() async throws {
        let recorder = StatusRecorder()
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "private-answer")])
        let agent = try makeAgent(engine, recorder: recorder)
        let initial = await agent.currentStatus
        XCTAssertNil(initial)
        _ = try await agent.run(request: request)
        let values = await recorder.values
        assertRun(values)
        let phases = values.map(\.phase).reduce(into: [BoneAgentStatus.Phase]()) { if $0.last != $1 { $0.append($1) } }
        XCTAssertEqual(phases, [.preparingInput, .checkingBudget, .waitingForModel, .validatingResponse, .finished(.succeeded)])
        XCTAssertTrue(values.dropFirst().allSatisfy { $0.step == 1 })
        let current = await agent.currentStatus
        XCTAssertEqual(current, values.last)
    }

    func testBufferedAndConversationShareSinkAndStartDistinctRuns() async throws {
        let recorder = StatusRecorder()
        let engine = StatusBufferedEngine()
        let agent = try makeAgent(engine, recorder: recorder, mode: .bufferedStreaming(.init(totalTimeout: 10)))
        let conversation = try await agent.makeConversation(modelID: "fixture", bindingID: "account")
        _ = try await conversation.send("private-prompt")
        _ = try await conversation.send(content: [.text("followup")])
        let values = await recorder.values
        let runs = Dictionary(grouping: values, by: \.runID)
        XCTAssertEqual(runs.count, 2)
        for run in runs.values { assertRun(run); XCTAssertFalse(run.contains { $0.phase == .reasoning }) }
        let counts = await engine.counts
        XCTAssertEqual(counts, [0, 2])
        let state = try await conversation.exportPrivateState()
        XCTAssertFalse(String(decoding: state, as: UTF8.self).contains("activeTools"))
        XCTAssertFalse(String(decoding: state, as: UTF8.self).contains("sequence"))
    }

    func testCustomEventStreamUpdatesStatusWithoutChangingContentEvents() async throws {
        let recorder = StatusRecorder()
        let agent = try makeAgent(StatusEventEngine(), recorder: recorder)
        var events: [BoneAgentStreamEvent] = []
        for try await event in try await agent.runEvents(request: request, options: .init(totalTimeout: 10)) { events.append(event) }
        let values = await recorder.values
        assertRun(values)
        XCTAssertTrue(values.contains { $0.phase == .reasoning })
        XCTAssertTrue(values.contains { $0.phase == .generatingResponse })
        XCTAssertEqual(values.filter { $0.phase == .reasoning }.count, 1)
        XCTAssertTrue(events.contains(.reasoningDelta(step: 1, text: "private-reasoning")))
        XCTAssertTrue(events.contains(.textDelta(step: 1, text: "private-answer")))
        guard case .completed = events.last else { return XCTFail("Missing formal completion") }
    }

    func testCustomActivityReportsHiddenReasoningWithoutText() async throws {
        let recorder = StatusRecorder()
        let agent = try makeAgent(StatusReportingEngine(), recorder: recorder)
        _ = try await agent.run(request: request)
        let values = await recorder.values
        assertRun(values)
        XCTAssertTrue(values.contains { $0.phase == .reasoning })
        XCTAssertTrue(values.contains { $0.phase == .resolvingImages })
        XCTAssertEqual(values.filter { $0.phase == .reasoning }.count, 1)
    }

    func testCompactionAndSummaryBeginBeforeWorkAndReturnToBudgeting() async throws {
        for summarizing in [false, true] {
            let recorder = StatusRecorder()
            let summary = StatusSummaryEngine(recorder: recorder)
            let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
            let binding = try BoneInferenceEngineContextSummarizer(engine: summary, modelID: "summary",
                budget: .init(contextWindowTokens: 16_384, source: .host))
            let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summarizing ? binding : nil,
                protocolReserveTokens: 0, safetyMarginTokens: 0)
            let agent = try makeAgent(BoneScriptedInferenceEngine(script: [.init(text: "done")]), recorder: recorder, context: policy)
            _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "old"),
                .init(role: .assistant, content: String(repeating: "historical data ", count: 300)),
                .init(role: .user, content: "current")])
            let values = await recorder.values
            assertRun(values)
            XCTAssertTrue(values.contains { $0.phase == .compactingContext })
            XCTAssertEqual(values.contains { $0.phase == .summarizingContext }, summarizing)
            let observed = await summary.phaseDuringInference
            XCTAssertEqual(observed, summarizing ? .summarizingContext : nil)
            let compact = try XCTUnwrap(values.firstIndex { $0.phase == .compactingContext })
            let waiting = try XCTUnwrap(values.firstIndex { $0.phase == .waitingForModel })
            XCTAssertLessThan(compact, waiting)
        }
    }

    func testSmallContextNeverClaimsCompaction() async throws {
        let recorder = StatusRecorder()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 4_096, maximumOutputTokens: 100, source: .host)
        let agent = try makeAgent(BoneScriptedInferenceEngine(script: [.init(text: "done")]), recorder: recorder,
            context: .init(budgetProvider: { _ in budget }))
        _ = try await agent.run(request: request)
        let values = await recorder.values
        XCTAssertFalse(values.contains { $0.phase == .compactingContext || $0.phase == .summarizingContext })
    }

    func testSummaryFallbackEndsSummarizingAndStillFinishes() async throws {
        let recorder = StatusRecorder()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let summarizer = try BoneInferenceEngineContextSummarizer(engine: BoneScriptedInferenceEngine(script: [.init(text: "")]),
            modelID: "summary", budget: .init(contextWindowTokens: 16_384, source: .host))
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: summarizer,
            protocolReserveTokens: 0, safetyMarginTokens: 0)
        let agent = try makeAgent(BoneScriptedInferenceEngine(script: [.init(text: "done")]), recorder: recorder, context: policy)
        _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: String(repeating: "old ", count: 1000)), .init(role: .user, content: "current")])
        let values = await recorder.values
        assertRun(values)
        let summaryIndex = try XCTUnwrap(values.firstIndex { $0.phase == .summarizingContext })
        XCTAssertEqual(values.dropFirst(summaryIndex + 1).first { $0.phase != .summarizingContext }?.phase, .compactingContext)
    }

    func testCompactionOverflowReportsFailureWithoutCallingEngine() async throws {
        let recorder = StatusRecorder()
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let agent = try makeAgent(engine, recorder: recorder, context: .init(budgetProvider: { _ in budget }, protocolReserveTokens: 0, safetyMarginTokens: 0))
        do {
            _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: String(repeating: "x", count: 4_000))])
            XCTFail("Mandatory input too large")
        } catch { XCTAssertEqual(error as? BoneAgentError, .contextManagementFailed) }
        let values = await recorder.values
        assertRun(values, terminal: .failed(.contextManagementFailed))
        XCTAssertTrue(values.contains { $0.phase == .compactingContext })
        XCTAssertFalse(values.contains { $0.phase == .waitingForModel })
        let sent = await engine.receivedRequests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testToolExecutesOnceInBothLegacyAndBatchedPaths() async throws {
        for legacy in [true, false] {
            let recorder = StatusRecorder()
            let counter = StatusToolCounter()
            let call = statusCall("one", ordinal: 0)
            let first = legacy ? BoneInferenceResponse.toolCall(call) : try toolResponse([call])
            let engine = BoneScriptedInferenceEngine(script: [first, .init(text: "done")])
            let agent = try makeAgent(engine, recorder: recorder, tools: [BoneAnyAgentTool(StatusTool(counter: counter))])
            _ = try await agent.run(request: request)
            let values = await recorder.values
            assertRun(values)
            let executed = await counter.ids
            XCTAssertEqual(executed, ["one"])
            let execution = try XCTUnwrap(values.first { $0.phase == .executingTools })
            XCTAssertEqual(execution.activeTools.map(\.callID), ["one"])
            XCTAssertEqual(execution.activeTools.first?.phase, .executing)
            XCTAssertTrue(values.contains { $0.phase == .processingToolResults })
            XCTAssertTrue(values.contains { $0.phase == .waitingForModel && $0.step == 2 })
        }
    }

    func testParallelToolsRemainVisibleAndObserverIsSerialized() async throws {
        let releaseSecond = StatusGate()
        let recorder = StatusRecorder(releaseSecond: releaseSecond)
        let barrier = StatusBarrier()
        let counter = StatusToolCounter()
        let tool = StatusTool(counter: counter, barrier: barrier, releaseSecond: releaseSecond)
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse([statusCall("a", ordinal: 0), statusCall("b", ordinal: 1)]), .init(text: "done")])
        let agent = try makeAgent(engine, recorder: recorder, tools: [BoneAnyAgentTool(tool)])
        _ = try await agent.run(request: request)
        let values = await recorder.values
        assertRun(values)
        XCTAssertTrue(values.contains { $0.activeTools.count == 2 && $0.activeTools.allSatisfy { $0.phase == .executing } })
        let two = try XCTUnwrap(values.lastIndex { $0.activeTools.count == 2 })
        XCTAssertEqual(values[two + 1].phase, .executingTools)
        XCTAssertEqual(values[two + 1].activeTools.map(\.callID), ["b"])
        let overlap = await recorder.maximumConcurrentCallbacks
        XCTAssertEqual(overlap, 1)
        let executed = await counter.ids
        XCTAssertEqual(Set(executed), ["a", "b"])
    }

    func testCollectedToolFailureClearsActiveToolsAndContinues() async throws {
        let recorder = StatusRecorder()
        let tool = StatusTool(counter: StatusToolCounter(), fails: true)
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse([statusCall("one", ordinal: 0)]), .init(text: "done")])
        let agent = try makeAgent(engine, recorder: recorder, tools: [BoneAnyAgentTool(tool)], strategy: .collectAll)
        _ = try await agent.run(request: request)
        let values = await recorder.values
        assertRun(values)
        XCTAssertTrue(values.contains { $0.phase == .processingToolResults && $0.activeTools.isEmpty })
        let requests = await engine.receivedRequests()
        XCTAssertTrue(try requests[1].messages.last?.requiredToolResults().results.first?.isError == true)
    }

    func testCancellationFromWaitingCallbackPreventsInference() async throws {
        let recorder = StatusRecorder()
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let task = Task {
            let agent = try BoneAgentBuilder(inferenceEngine: engine).withConfiguration(.init(maximumSteps: 1, statusSink: .init {
                await recorder.receive($0)
                if $0.phase == .waitingForModel { withUnsafeCurrentTask { $0?.cancel() } }
            })).build()
            return try await agent.run(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "hi")]))
        }
        do { _ = try await task.value; XCTFail("Cancelled before engine") } catch { XCTAssertTrue(error is CancellationError) }
        let values = await recorder.values
        assertRun(values, terminal: .cancelled)
        let sent = await engine.receivedRequests()
        XCTAssertTrue(sent.isEmpty)
    }

    func testCancellationFromToolCallbackPreventsToolBody() async throws {
        let recorder = StatusRecorder()
        let counter = StatusToolCounter()
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse([statusCall("one", ordinal: 0)])])
        let task = Task {
            let agent = try BoneAgentBuilder(inferenceEngine: engine).withTool(StatusTool(counter: counter))
                .withConfiguration(.init(maximumSteps: 2, statusSink: .init {
                    await recorder.receive($0)
                    if $0.phase == .executingTools { withUnsafeCurrentTask { $0?.cancel() } }
                })).build()
            return try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
        }
        do { _ = try await task.value; XCTFail("Tool must not start") } catch { XCTAssertTrue(error is CancellationError) }
        let values = await recorder.values
        assertRun(values, terminal: .cancelled)
        let executed = await counter.ids
        XCTAssertTrue(executed.isEmpty)
    }

    func testLateCancellationInTerminalObserverDoesNotReplaceSuccess() async throws {
        let recorder = StatusRecorder()
        let task = Task {
            let agent = try BoneAgentBuilder(inferenceEngine: BoneScriptedInferenceEngine(script: [.init(text: "done")]))
                .withConfiguration(.init(maximumSteps: 1, statusSink: .init {
                    await recorder.receive($0)
                    if $0.isTerminal { withUnsafeCurrentTask { $0?.cancel() } }
                })).build()
            return try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
        }
        let completed = try await task.value
        XCTAssertEqual(completed.output, .text("done"))
        let values = await recorder.values
        assertRun(values)
    }

    func testReentrantRunRejectedWithoutReplacingCurrentStatus() async throws {
        let recorder = StatusRecorder()
        let holder = StatusAgentHolder()
        let agent = try BoneAgentBuilder(inferenceEngine: BoneScriptedInferenceEngine(script: [.init(text: "done")]))
            .withConfiguration(.init(maximumSteps: 1, statusSink: .init { value in
                await recorder.receive(value)
                if value.phase == .waitingForModel, let agent = await holder.agent {
                    let snapshot = await agent.currentStatus
                    XCTAssertEqual(snapshot?.runID, value.runID)
                    do { _ = try await agent.run(modelID: "fixture", messages: []); XCTFail("Reentry must fail") }
                    catch { XCTAssertEqual(error as? BoneAgentError, .runAlreadyInProgress) }
                }
            })).build()
        await holder.set(agent)
        _ = try await agent.run(request: request)
        let values = await recorder.values
        assertRun(values)
    }

    func testPreflightFailureHasTerminalButRejectedStreamDoesNotStartRun() async throws {
        let recorder = StatusRecorder()
        let agent = try makeAgent(BoneScriptedInferenceEngine(script: []), recorder: recorder)
        do { _ = try await agent.runEvents(request: request, options: .init()); XCTFail("No event streaming") }
        catch { XCTAssertEqual(error as? BoneAgentError, .unsupportedCapability(.streaming)) }
        let before = await recorder.values
        XCTAssertTrue(before.isEmpty)
        do { _ = try await agent.run(request: .init(modelID: "fixture", messages: request.messages,
            generationOptions: .init(reasoning: .init(selection: .level(.high))))); XCTFail("No profile") }
        catch { XCTAssertEqual(error as? BoneAgentError, .inferenceFailed) }
        let values = await recorder.values
        assertRun(values, terminal: .failed(.inferenceFailed))
    }

    func testLateInferenceActivityCannotRegressNextStepOrTerminal() async throws {
        let recorder = StatusRecorder()
        let status = BoneAgentStatusReporter(sink: .init { await recorder.receive($0) })
        await status.transition(.preparingInput)
        let old = await status.beginInference(step: 1)
        await status.endInference(old)
        let current = await status.beginInference(step: 2)
        await status.inferenceActivity(.reasoning, id: old)
        let waiting = await status.current
        XCTAssertEqual(waiting?.phase, .waitingForModel)
        await status.transition(.finished(.succeeded))
        await status.inferenceActivity(.generatingResponse, id: current)
        let values = await recorder.values
        assertRun(values)
        XCTAssertFalse(values.contains { $0.phase == .reasoning || $0.phase == .generatingResponse })
    }

    func testBuiltInProviderReportsHiddenReasoningThroughAgent() async throws {
        let recorder = StatusRecorder()
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .openAI, apiKey: "synthetic",
            baseURL: URL(string: "https://fixture.invalid")!), transport: StatusProviderTransport())
        let agent = try makeAgent(engine, recorder: recorder)
        var events: [BoneAgentStreamEvent] = []
        for try await event in try await agent.runEvents(request: request, options: .init(totalTimeout: 10)) { events.append(event) }
        let values = await recorder.values
        assertRun(values)
        XCTAssertTrue(values.contains { $0.phase == .reasoning })
        XCTAssertTrue(values.contains { $0.phase == .generatingResponse })
        XCTAssertFalse(events.contains {
            switch $0 { case .reasoningStarted, .reasoningDelta, .reasoningCompleted: return true; default: return false }
        })
        let generating = try XCTUnwrap(values.firstIndex { $0.phase == .generatingResponse })
        XCTAssertFalse(values.suffix(from: generating).contains { $0.phase == .reasoning })
    }

    func testFailFastToolFailureEndsStatusWithNoActiveTools() async throws {
        let recorder = StatusRecorder()
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse([statusCall("one", ordinal: 0)])])
        let agent = try makeAgent(engine, recorder: recorder, tools: [BoneAnyAgentTool(StatusTool(counter: StatusToolCounter(), fails: true))])
        do { _ = try await agent.run(request: request); XCTFail("Expected tool failure") }
        catch { XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed) }
        let values = await recorder.values
        assertRun(values, terminal: .failed(.toolExecutionFailed))
    }

    func testCancellationAtCompactionStartNeverCallsSummaryOrBusinessEngine() async throws {
        let recorder = StatusRecorder()
        let business = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let summary = BoneScriptedInferenceEngine(script: [.init(text: "unused")])
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let binding = try BoneInferenceEngineContextSummarizer(engine: summary, modelID: "summary",
            budget: .init(contextWindowTokens: 16_384, source: .host))
        let task = Task {
            let agent = try BoneAgentBuilder(inferenceEngine: business).withConfiguration(.init(maximumSteps: 1,
                contextManagement: .init(budgetProvider: { _ in budget }, summarizer: binding, protocolReserveTokens: 0, safetyMarginTokens: 0),
                statusSink: .init {
                    await recorder.receive($0)
                    if $0.phase == .compactingContext { withUnsafeCurrentTask { $0?.cancel() } }
                })).build()
            return try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: String(repeating: "old ", count: 1000)), .init(role: .user, content: "current")])
        }
        do { _ = try await task.value; XCTFail("Cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let values = await recorder.values
        assertRun(values, terminal: .cancelled)
        let sent = await business.receivedRequests()
        let summarized = await summary.receivedRequests()
        XCTAssertTrue(sent.isEmpty && summarized.isEmpty)
    }
}

private extension BoneAgentBuilder {
    func withToolsForStatusTest(_ tools: [BoneAnyAgentTool]) -> Self { tools.reduce(self) { $0.withTool($1) } }
}
private actor StatusRecorder {
    var values: [BoneAgentStatus] = []
    var maximumConcurrentCallbacks = 0
    private var callbacks = 0
    private var sawBoth = false
    private let releaseSecond: StatusGate?
    init(releaseSecond: StatusGate? = nil) { self.releaseSecond = releaseSecond }
    func receive(_ status: BoneAgentStatus) async {
        callbacks += 1
        maximumConcurrentCallbacks = max(maximumConcurrentCallbacks, callbacks)
        await Task.yield()
        values.append(status)
        if status.activeTools.count == 2 { sawBoth = true }
        if sawBoth && status.activeTools.map(\.callID) == ["b"] { await releaseSecond?.open() }
        callbacks -= 1
    }
}
private actor StatusGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !opened { await withCheckedContinuation { waiters.append($0) } } }
    func open() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
private actor StatusBarrier {
    private var arrivals = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func arrive() async {
        arrivals += 1
        if arrivals == 2 { waiter?.resume(); waiter = nil }
        else { await withCheckedContinuation { waiter = $0 } }
    }
}
private actor StatusToolCounter { var ids: [String] = []; func add(_ id: String) { ids.append(id) } }
private actor StatusAgentHolder { var agent: BoneAgent?; func set(_ agent: BoneAgent) { self.agent = agent } }
private enum StatusTestError: Error { case fixtureFailure }
private struct StatusTool: BoneAgentTool {
    struct Input: Codable, Sendable { let id: String }
    typealias Output = String
    typealias Context = BoneAgentEmptyContext
    let counter: StatusToolCounter
    var barrier: StatusBarrier? = nil
    var releaseSecond: StatusGate? = nil
    var fails = false
    static var definition: BoneAgentToolDefinition {
        .init(id: "status.tool", version: "1", title: "Read", summary: "Read public fixture", wireName: "status_tool", schemaVersion: 1,
            inputSchema: .object(properties: ["id": .string(enumValues: [], minimumLength: nil, maximumLength: nil)], required: ["id"], additionalProperties: false),
            executionPolicy: .parallelSafe(resourceKeys: []), impact: .ordinaryPublicRead)
    }
    func execute(input: Input, context: Context) async throws -> String {
        await counter.add(input.id)
        await barrier?.arrive()
        if input.id == "b" { await releaseSecond?.wait() }
        if fails { throw StatusTestError.fixtureFailure }
        return "private-answer"
    }
}
private func statusCall(_ id: String, ordinal: Int) -> BoneInferenceToolCall {
    .init(id: id, toolID: StatusTool.definition.id, arguments: Data("{\"id\":\"\(id)\"}".utf8), ordinal: ordinal)
}
private func toolResponse(_ calls: [BoneInferenceToolCall]) throws -> BoneInferenceResponse {
    .assistantTurn(turn: try .init(content: calls.map { .toolCall($0) }), finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil)
}
private struct StatusReportingEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        for activity in [BoneInferenceActivity.resolvingImages, .waitingForModel, .reasoning, .reasoning, .generatingResponse] {
            await BoneInferenceActivityReporting.report(activity)
        }
        return .init(text: "private-answer")
    }
}
private actor StatusBufferedEngine: BoneInferenceEngine, BoneInferenceBufferedStreaming {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    var counts = [0, 0]
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { counts[0] += 1; return .init(text: "done") }
    func inferUsingStream(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceResponse {
        counts[1] += 1; return .init(text: "done")
    }
}
private struct StatusEventEngine: BoneInferenceEngine, BoneInferenceEventStreaming {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "unused") }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        .init {
            $0.yield(.reasoningStarted(kind: .providerReadable))
            $0.yield(.reasoningDelta("private-reasoning"))
            $0.yield(.reasoningCompleted)
            $0.yield(.textDelta("private-answer"))
            $0.yield(.completed(.init(response: .init(text: "private-answer"), reasoning: nil)))
            $0.finish()
        }
    }
}
private actor StatusSummaryEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let recorder: StatusRecorder
    var phaseDuringInference: BoneAgentStatus.Phase?
    init(recorder: StatusRecorder) { self.recorder = recorder }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        phaseDuringInference = await recorder.values.last?.phase
        return .init(text: "Earlier task completed; current task remains.")
    }
}

private struct StatusProviderTransport: BoneInferenceHTTPTransport {
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { throw StatusTestError.fixtureFailure }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: [
            #"{"choices":[{"index":0,"delta":{"reasoning_content":"private-reasoning"}}]}"#,
            #"{"choices":[{"index":0,"delta":{"content":"private-answer"}}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, "[DONE]"
        ].map { .init(data: $0) })
    }
}
