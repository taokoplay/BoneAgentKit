import XCTest
@testable import BoneAgentKit

final class BoneAgentTests: XCTestCase {
    func testLegacyToolHonorsFirstToolTurnBoundary() async throws {
        let call = BoneInferenceToolCall(id: "call-1", toolID: ProbeEchoTool.definition.id,
            arguments: try JSONEncoder().encode(ProbeEchoTool.Input(value: "ok")))
        let engine = RequestCapturingEngine(script: [.toolCall(call), .finish(.init(text: "late"))])
        let agent = BoneAgent(inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())]),
            toolContext: BoneAgentEmptyContext(), configuration: try BoneAgentConfiguration(maximumSteps: 2))
        let result = try await agent.runUntilBoundary(request: .init(modelID: "model", messages: []), boundary: .afterFirstToolTurn)
        XCTAssertEqual(result.completion, .toolTurnCompleted)
        let count = await engine.inferenceCount()
        XCTAssertEqual(count, 1)
    }

    func testTurnBudgetStopsBeforeSecondInference() async throws {
        let call = BoneInferenceToolCall(id: "call-1", toolID: ProbeEchoTool.definition.id,
            arguments: try JSONEncoder().encode(ProbeEchoTool.Input(value: "ok")))
        let engine = RequestCapturingEngine(script: [.toolCall(call), .finish(.init(text: "late"))])
        let budget = try BoneRunBudget(maximumInferenceCalls: 3, maximumToolCalls: 3,
            maximumInputBytes: 100_000, maximumOutputBytes: 100_000, maximumTurns: 1,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 100)
        let agent = BoneAgent(inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())]),
            toolContext: BoneAgentEmptyContext(), configuration: try BoneAgentConfiguration(
                maximumSteps: 3, runBudget: budget, inferenceCostEstimator: { _ in 0 }))
        do { _ = try await agent.run(modelID: "model", messages: []); XCTFail("expected budget failure") }
        catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
        let count = await engine.inferenceCount()
        XCTAssertEqual(count, 1)
    }

    func testLateCancelledToolResultIsNotPublishedForEitherResponseShape() async throws {
        for legacy in [true, false] {
            let gate = BudgetToolGate()
            let recorder = ProgressRecorder()
            let events = BudgetEventRecorder()
            let call = BoneInferenceToolCall(id: "call-1", toolID: GatedBudgetTool.definition.id,
                arguments: try JSONEncoder().encode(ProbeEchoTool.Input(value: "ok")))
            let response: BoneInferenceResponse = legacy ? .toolCall(call) : .assistantTurn(
                turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls,
                usage: nil, refusal: nil, providerContinuation: nil)
            let engine = RequestCapturingEngine(script: [response, .finish(.init(text: "late"))])
            let agent = BoneAgent(inferenceEngine: engine,
                toolRegistry: try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(GatedBudgetTool(gate: gate))]),
                toolContext: BoneAgentEmptyContext(), configuration: try BoneAgentConfiguration(maximumSteps: 2),
                eventSink: events.sink(), progressSink: recorder.sink())
            let task = Task { try await agent.run(modelID: "model", messages: []) }
            await gate.waitUntilEntered()
            task.cancel()
            await gate.release()
            do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
            let progress = await recorder.values()
            XCTAssertFalse(progress.contains { if case .toolResultPrepared = $0 { return true }; return false })
            let values = await events.values()
            XCTAssertFalse(values.contains(.toolCallFinished))
            XCTAssertTrue(values.contains(.runFinished(.cancelled)))
            let count = await engine.inferenceCount()
            XCTAssertEqual(count, 1)
        }
    }

    func testClockExpiresAtInferenceCompletionOrSuccessBoundary() async throws {
        for expireInProgress in [false, true] {
            let clock = BudgetTestClock()
            let events = BudgetEventRecorder()
            let engine = BudgetClockEngine { if !expireInProgress { clock.advance() } }
            let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []),
                toolContext: BoneAgentEmptyContext(), configuration: try clockBudgetConfiguration(),
                eventSink: events.sink(), progressSink: .init { value in
                    if expireInProgress, case .inferenceResponsePrepared = value { clock.advance() }
                }, monotonicClock: { clock.now() })
            do { _ = try await agent.run(modelID: "model", messages: []); XCTFail("deadline must reject success") }
            catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
            let values = await events.values()
            XCTAssertFalse(values.contains(.runFinished(.succeeded)))
        }
    }

    func testClockExpiresAtToolCompletionForEitherResponseShape() async throws {
        for legacy in [true, false] {
            let clock = BudgetTestClock()
            let gate = BudgetToolGate()
            let progress = ProgressRecorder()
            let call = BoneInferenceToolCall(id: "call-1", toolID: GatedBudgetTool.definition.id,
                arguments: try JSONEncoder().encode(ProbeEchoTool.Input(value: "ok")))
            let response: BoneInferenceResponse = legacy ? .toolCall(call) : .assistantTurn(
                turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls,
                usage: nil, refusal: nil, providerContinuation: nil)
            let engine = RequestCapturingEngine(script: [response])
            let agent = BoneAgent(inferenceEngine: engine,
                toolRegistry: try .init(tools: [BoneAnyAgentTool(GatedBudgetTool(gate: gate))]),
                toolContext: BoneAgentEmptyContext(), configuration: try clockBudgetConfiguration(),
                progressSink: progress.sink(), monotonicClock: { clock.now() })
            let task = Task { try await agent.runUntilBoundary(request: .init(modelID: "model", messages: []), boundary: .afterFirstToolTurn) }
            await gate.waitUntilEntered()
            clock.advance()
            await gate.release()
            do { _ = try await task.value; XCTFail("deadline must reject late tool") }
            catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
            let values = await progress.values()
            XCTAssertFalse(values.contains { if case .toolResultPrepared = $0 { return true }; return false })
        }
    }

    func testDeadlineDoesNotRetractSuccessOnceTerminalDeliveryStarts() async throws {
        let clock = BudgetTestClock()
        let agent = BoneAgent(inferenceEngine: RequestCapturingEngine(), toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(), configuration: try clockBudgetConfiguration(),
            eventSink: .init { event in
                if event == .runFinished(.succeeded) { clock.advance() }
            }, monotonicClock: { clock.now() })
        let result = try await agent.run(modelID: "model", messages: [])
        XCTAssertEqual(result.output, .text("done"))
    }

    func testContextProviderReturnRejectsCancellationAndDeadlineBeforeToolEntry() async throws {
        for legacy in [true, false] {
            for cancel in [true, false] {
                let clock = BudgetTestClock()
                let gate = BudgetToolGate()
                let counter = BudgetToolEntryCounter()
                let events = BudgetEventRecorder()
                let progress = ProgressRecorder()
                let call = BoneInferenceToolCall(id: "call-1", toolID: CountingBudgetTool.definition.id,
                    arguments: try JSONEncoder().encode(ProbeEchoTool.Input(value: "ok")))
                let response: BoneInferenceResponse = legacy ? .toolCall(call) : .assistantTurn(
                    turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls,
                    usage: nil, refusal: nil, providerContinuation: nil)
                let engine = RequestCapturingEngine(script: [response, .finish(.init(text: "late"))])
                let configuration = try BoneAgentConfiguration(maximumSteps: 2,
                    runBudget: clockBudgetConfiguration().runBudget, inferenceCostEstimator: { _ in 0 },
                    toolExecutionContextProvider: { _, _ in
                        await gate.suspend()
                        return nil
                    })
                let agent = BoneAgent(inferenceEngine: engine,
                    toolRegistry: try .init(tools: [BoneAnyAgentTool(CountingBudgetTool(counter: counter))]),
                    toolContext: BoneAgentEmptyContext(), configuration: configuration,
                    eventSink: events.sink(), progressSink: progress.sink(), monotonicClock: { clock.now() })
                let task = Task { try await agent.runUntilBoundary(
                    request: .init(modelID: "model", messages: []), boundary: .afterFirstToolTurn) }
                await gate.waitUntilEntered()
                if cancel { task.cancel() } else { clock.advance() }
                await gate.release()
                let scenario = "legacy=\(legacy), cancel=\(cancel)"
                do { _ = try await task.value; XCTFail("must reject: " + scenario) }
                catch {
                    if cancel { XCTAssertTrue(error is CancellationError, scenario) }
                    else { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded, scenario) }
                }
                let entries = await counter.value()
                XCTAssertEqual(entries, 0, "must not start tool after provider returns: " + scenario)
                let inferenceCount = await engine.inferenceCount()
                XCTAssertEqual(inferenceCount, 1, scenario)
                let recorded = await progress.values()
                XCTAssertFalse(recorded.contains { if case .toolResultPrepared = $0 { return true }; return false }, scenario)
                let terminalEvents = await events.values()
                XCTAssertFalse(terminalEvents.contains(.runFinished(.succeeded)), scenario)
            }
        }
    }

    private func clockBudgetConfiguration() throws -> BoneAgentConfiguration {
        try BoneAgentConfiguration(maximumSteps: 2, runBudget: .init(maximumInferenceCalls: 3,
            maximumToolCalls: 3, maximumInputBytes: 100_000, maximumOutputBytes: 100_000,
            maximumTurns: 3, maximumWallClockSeconds: 5, maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: 100), inferenceCostEstimator: { _ in 0 })
    }

    /// 验证公共 Tool Result 工厂对非法调用标识返回稳定错误，而不是终止进程。
    func testToolResultFactoryRejectsInvalidCallID() {
        XCTAssertThrowsError(
            try BoneInferenceMessage.toolResult(
                callID: "",
                toolID: "echo",
                result: Data(#"{\"ok\":true}"#.utf8)
            )
        ) { error in
            XCTAssertEqual(error as? BoneInferenceError, .invalidToolResult)
        }
    }

    func testAfterFirstToolTurnBoundaryExecutesToolsAndStopsBeforeSecondInference() async throws {
        let arguments = try JSONEncoder().encode(ProbeEchoTool.Input(value: "candidate"))
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(id: "call-1", toolID: ProbeEchoTool.definition.id, arguments: arguments)),
        ])
        let engine = RequestCapturingEngine(script: [
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil),
            .finish(.init(text: "must-not-run")),
        ])
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2)
        )

        let result = try await agent.runUntilBoundary(
            request: BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "scan")]),
            boundary: .afterFirstToolTurn
        )

        XCTAssertEqual(result, BoneAgentBoundaryResult(completion: .toolTurnCompleted, steps: 1))
        let inferenceCount = await engine.inferenceCount()
        XCTAssertEqual(inferenceCount, 1)
    }

    func testAfterFirstToolTurnBoundaryStillReturnsNormalModelFinishWithoutTools() async throws {
        let engine = RequestCapturingEngine(script: [.finish(.init(text: "done"))])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1)
        )

        let result = try await agent.runUntilBoundary(
            request: BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "scan")]),
            boundary: .afterFirstToolTurn
        )

        XCTAssertEqual(result, BoneAgentBoundaryResult(completion: .modelFinished(.text("done")), steps: 1))
        let inferenceCount = await engine.inferenceCount()
        XCTAssertEqual(inferenceCount, 1)
    }

    func testAuthorizedPrivateLocalReadDoesNotRequireEffectStore() async throws {
        let arguments = try JSONEncoder().encode(ProbeEchoTool.Input(value: "private"))
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(id: "call-1", toolID: PrivateReadProbeTool.definition.id, arguments: arguments)),
        ])
        let engine = RequestCapturingEngine(script: [
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil),
            .finish(.init(text: "done")),
        ])
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(PrivateReadProbeTool())])
        let policy = BoneToolImpactPolicy(maximumAllowed: PrivateReadProbeTool.definition.impact!)
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 2, toolImpactPolicy: policy)
        )

        let result = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])

        XCTAssertEqual(result.steps, 2)
    }

    func testInferenceFailurePublishesStableTransportDiagnosticWithoutPayload() async throws {
        let engine = StableFailureEngine(error: BoneInferenceTransportError.firstEventTimedOut)
        let recorder = ProgressRecorder()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1),
            progressSink: recorder.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])
            XCTFail("transport failure must fail the run")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .inferenceFailed)
        }
        let values = await recorder.values()
        XCTAssertTrue(values.contains(.inferenceFailed(.firstEventTimedOut)))
    }

    func testProtocolShapeFailurePublishesSafeShapeAndStableInvalidResponse() async throws {
        let diagnostic = BoneInferenceProtocolShapeDiagnostic.openAI(
            events: [BoneInferenceEventStreamEvent(data: "PRIVATE-NOT-JSON")],
            failureStage: .eventJSON
        )
        let engine = StableFailureEngine(error: BoneInferenceProtocolShapeError(diagnostic: diagnostic))
        let recorder = ProgressRecorder()
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try BoneAgentToolRegistry(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1),
            progressSink: recorder.sink()
        )

        do {
            _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "scan")])
            XCTFail("protocol failure must fail the run")
        } catch let error as BoneAgentError {
            XCTAssertEqual(error, .inferenceFailed)
        }
        let values = await recorder.values()
        XCTAssertTrue(values.contains(.inferenceProtocolShapeFailed(diagnostic)))
        XCTAssertTrue(values.contains(.inferenceFailed(.invalidResponse)))
        XCTAssertFalse(diagnostic.summary.contains("PRIVATE"))
    }

    func testRunRequestPreservesGenerationOptionsAndReasoningWhileInjectingRegistryTools() async throws {
        let engine = RequestCapturingEngine()
        let registry = try BoneAgentToolRegistry(tools: [BoneAnyAgentTool(ProbeEchoTool())])
        let agent = BoneAgent(
            inferenceEngine: engine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: try BoneAgentConfiguration(maximumSteps: 1)
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "scan")],
            generationOptions: .init(temperature: 0.2, maximumOutputTokens: 2_048),
            reasoningDisclosure: .hidden
        )

        _ = try await agent.run(request: request)

        let captured = await engine.lastRequest()
        let recorded = try XCTUnwrap(captured)
        XCTAssertEqual(recorded.modelID, "model")
        XCTAssertEqual(recorded.messages, request.messages)
        XCTAssertEqual(recorded.generationOptions, request.generationOptions)
        XCTAssertEqual(recorded.reasoningDisclosure, .hidden)
        XCTAssertEqual(recorded.responseFormat, .text)
        XCTAssertEqual(recorded.availableTools.map(\.id), registry.definitions.map(\.id))
    }
}

private actor ProgressRecorder {
    private var recorded = [BoneAgentProgress]()

    nonisolated func sink() -> BoneAgentProgressSink {
        BoneAgentProgressSink { [weak self] value in
            await self?.record(value)
        }
    }

    func record(_ value: BoneAgentProgress) { recorded.append(value) }
    func values() -> [BoneAgentProgress] { recorded }
}

private struct StableFailureEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let error: any Error

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        throw error
    }
}

private actor RequestCapturingEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var request: BoneInferenceRequest?
    private var script: [BoneInferenceResponse]
    private var inferenceCallCount = 0

    init(script: [BoneInferenceResponse] = [.finish(.init(text: "done"))]) {
        self.script = script
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        self.request = request
        inferenceCallCount += 1
        guard !script.isEmpty else { throw BoneInferenceError.invalidResponse }
        return script.removeFirst()
    }

    func lastRequest() -> BoneInferenceRequest? { request }
    func inferenceCount() -> Int { inferenceCallCount }
}

private struct PrivateReadProbeTool: BoneAgentTool {
    typealias Input = ProbeEchoTool.Input
    typealias Output = ProbeEchoTool.Output
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.private-read",
        version: "1",
        title: "Private Read",
        summary: "Read already-authorized local private context",
        wireName: "private_read",
        schemaVersion: 1,
        inputSchema: ProbeEchoTool.definition.inputSchema!,
        impact: BoneToolImpact(
            dataAccess: .userPrivate,
            externalTransmission: .none,
            stateChange: .none,
            economic: .none,
            userVisible: .none,
            permissionChange: .none
        )
    )

    func execute(input: Input, context: Context) async throws -> Output {
        Output(value: input.value)
    }
}

private struct ProbeEchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }
    typealias Context = BoneAgentEmptyContext

    static let definition = BoneAgentToolDefinition(
        id: "test.probe-echo",
        version: "1",
        title: "Probe Echo",
        summary: "Echo probe input",
        wireName: "probe_echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: [
                "value": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
            ],
            required: ["value"],
            additionalProperties: false
        ),
        impact: .ordinaryPublicRead
    )

    func execute(input: Input, context: BoneAgentEmptyContext) async throws -> Output {
        Output(value: input.value)
    }
}

private final class BudgetTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 100
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
    func advance() { lock.lock(); defer { lock.unlock() }; time = 106 }
}

private struct BudgetClockEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let onInfer: @Sendable () -> Void
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        onInfer()
        return .finish(.init(text: "done"))
    }
}

private actor BudgetEventRecorder {
    private var recorded: [BoneAgentEvent] = []
    nonisolated func sink() -> BoneAgentEventSink { .init { await self.record($0) } }
    func record(_ value: BoneAgentEvent) { recorded.append(value) }
    func values() -> [BoneAgentEvent] { recorded }
}

private actor BudgetToolGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func suspend() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}

private struct GatedBudgetTool: BoneAgentTool {
    typealias Input = ProbeEchoTool.Input
    typealias Output = ProbeEchoTool.Output
    typealias Context = BoneAgentEmptyContext
    static let definition = ProbeEchoTool.definition
    let gate: BudgetToolGate
    func execute(input: Input, context: Context) async throws -> Output {
        await gate.suspend()
        return .init(value: input.value)
    }
}

private actor BudgetToolEntryCounter {
    private var entries = 0
    func enter() { entries += 1 }
    func value() -> Int { entries }
}

private struct CountingBudgetTool: BoneAgentTool {
    typealias Input = ProbeEchoTool.Input
    typealias Output = ProbeEchoTool.Output
    typealias Context = BoneAgentEmptyContext
    static let definition = ProbeEchoTool.definition
    let counter: BudgetToolEntryCounter
    func execute(input: Input, context: Context) async throws -> Output {
        await counter.enter()
        return .init(value: input.value)
    }
}
