import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class AgentObservedEventTests: XCTestCase {
    func testEnvelopesShareStatusAndTokenIdentityAndHaveIndependentSequence() async throws {
        let records = ObservedRecords()
        let engine = ObservedScriptEngine([.text(["你好", "🌊"], "你好🌊")])
        let agent = try makeAgent(engine, records: records)
        let stream = try await agent.runObservedEvents(request: request, options: .init(totalTimeout: 2))
        var events: [BoneAgentObservedEvent] = []
        for try await event in stream { events.append(event) }
        XCTAssertEqual(events.map(\.sequence), Array(1...UInt64(events.count)))
        XCTAssertTrue(events.allSatisfy { $0.runID == stream.runID })
        XCTAssertEqual(events.first?.event, .runStarted)
        XCTAssertEqual(events.last?.event, .completed(.init(completion: .modelFinished(.text("你好🌊")), steps: 1)))
        let statuses = await records.statuses
        let tokens = await records.tokens
        XCTAssertFalse(statuses.isEmpty)
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(statuses.allSatisfy { $0.runID == stream.runID })
        XCTAssertTrue(tokens.allSatisfy { $0.runID == stream.runID })
        XCTAssertEqual(statuses.last?.phase, .finished(.succeeded))

        let second = try await agent.runObservedEvents(request: request, options: .init(totalTimeout: 2))
        XCTAssertNotEqual(second.runID, stream.runID)
        var firstSequence: UInt64?
        for try await event in second { if firstSequence == nil { firstSequence = event.sequence } }
        XCTAssertEqual(firstSequence, 1)
    }

    func testSlowConsumerRetainsAllDeltasAndRespectsQueueCapacity() async throws {
        let chunks = (0..<1_024).map { "\($0)," }
        let engine = ObservedScriptEngine([.text(chunks, chunks.joined())])
        let agent = try makeAgent(engine)
        let limits = try BoneEventBufferLimits(maximumEventCount: 2,
            maximumQueuedPayloadBytes: 32_768, maximumEventPayloadBytes: 32_768)
        let stream = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 10), buffering: limits)
        var text = ""
        var completions = 0
        for try await envelope in stream {
            switch envelope.event {
            case .textDelta(_, let delta): text += delta
            case .completed: completions += 1
            default: break
            }
            await Task.yield()
        }
        XCTAssertEqual(text, chunks.joined())
        XCTAssertEqual(completions, 1)
        XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedEventCount, 2)
        XCTAssertLessThanOrEqual(stream.bufferSnapshot.peakBufferedPayloadBytes, limits.maximumQueuedPayloadBytes)
        XCTAssertEqual(engine.invocationCount, 1)
    }

    func testCompletionHasReservedSlotWhenUnconsumedBodyQueueIsFull() async throws {
        let terminal = expectation(description: "execution finishes without a consumer")
        let agent = try makeAgent(ObservedScriptEngine([.text(["x"], "x")]), terminal: terminal)
        let limits = try BoneEventBufferLimits(maximumEventCount: 2,
            maximumQueuedPayloadBytes: 4_096, maximumEventPayloadBytes: 4_096)
        let stream = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 2), buffering: limits)
        await fulfillment(of: [terminal], timeout: 3)
        var events: [BoneAgentStreamEvent] = []
        for try await envelope in stream { events.append(envelope.event) }
        XCTAssertEqual(events, [.runStarted, .textDelta(step: 1, text: "x"),
            .completed(.init(completion: .modelFinished(.text("x")), steps: 1))])
        XCTAssertEqual(stream.bufferSnapshot.peakBufferedEventCount, 2)
        _ = try await agent.run(modelID: "model", messages: request.messages)
    }

    func testMissingFormalCompletionCannotBecomeSuccessfulObservation() async throws {
        let agent = try makeAgent(ObservedScriptEngine([.missing]))
        let stream = try await agent.runObservedEvents(request: request, options: .init(totalTimeout: 2))
        var events: [BoneAgentStreamEvent] = []
        do {
            for try await envelope in stream { events.append(envelope.event) }
            XCTFail("Expected formal completion validation failure")
        } catch { XCTAssertEqual(error as? BoneAgentError, .inferenceFailed) }
        XCTAssertTrue(events.contains(.textDelta(step: 1, text: "partial")))
        XCTAssertFalse(events.contains { if case .completed = $0 { return true }; return false })
        _ = try await agent.run(modelID: "model", messages: request.messages)
    }

    func testUnsupportedFlowControlDoesNotStartOrReplaceExistingRun() async throws {
        let records = ObservedRecords()
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "legacy")])
        let agent = try makeAgent(engine, records: records)
        _ = try await agent.run(modelID: "model", messages: request.messages)
        let before = await agent.currentStatus
        do {
            _ = try await agent.runObservedEvents(request: request, options: .init(totalTimeout: 2))
            XCTFail("Legacy-only engine must explicitly reject flow control")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .flowControlUnavailable) }
        let after = await agent.currentStatus
        XCTAssertEqual(after, before)
    }

    func testExpiredRequestIsRejectedBeforeCreatingObservationIdentity() async throws {
        let records = ObservedRecords()
        let engine = ObservedScriptEngine([.text(["unused"], "unused")])
        let agent = try makeAgent(engine, records: records)
        do {
            _ = try await agent.runObservedEvents(request: request,
                options: .init(deadlineUptime: ProcessInfo.processInfo.systemUptime - 1))
            XCTFail("Expired request must not start")
        } catch { XCTAssertTrue(error is BoneInferenceStreamDeadlineExceeded) }
        let statuses = await records.statuses
        XCTAssertTrue(statuses.isEmpty)
        XCTAssertEqual(engine.invocationCount, 0)
    }

    func testInferenceDeadlineInterruptsAgentBackpressureWithoutConsumer() async throws {
        let terminal = expectation(description: "deadline ends blocked inference")
        let records = ObservedRecords()
        let agent = try makeAgent(ObservedScriptEngine([.text(Array(repeating: "delta", count: 100), "answer")]),
            records: records, terminal: terminal)
        let limits = try BoneEventBufferLimits(maximumEventCount: 1,
            maximumQueuedPayloadBytes: 4_096, maximumEventPayloadBytes: 4_096)
        let stream = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 0.05), buffering: limits)
        await fulfillment(of: [terminal], timeout: 3)
        do {
            for try await _ in stream {}
            XCTFail("Expected inference deadline while awaiting downstream capacity")
        } catch { XCTAssertTrue(error is BoneInferenceStreamDeadlineExceeded, "\(error)") }
        let status = await records.statuses.last
        XCTAssertEqual(status?.phase, .finished(.failed(.inferenceFailed)))
        _ = try await agent.run(modelID: "model", messages: request.messages)
    }

    func testBreakingObservationCancelsBlockedExecutionAndReleasesAgent() async throws {
        let terminal = expectation(description: "cancelled execution")
        let records = ObservedRecords()
        let agent = try makeAgent(ObservedScriptEngine([.text(Array(repeating: "delta", count: 1_000), "answer")]),
            records: records, terminal: terminal)
        let limits = try BoneEventBufferLimits(maximumEventCount: 1,
            maximumQueuedPayloadBytes: 4_096, maximumEventPayloadBytes: 4_096)
        let stream = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 5), buffering: limits)
        for try await envelope in stream {
            XCTAssertEqual(envelope.event, .runStarted)
            break
        }
        await fulfillment(of: [terminal], timeout: 3)
        let status = await records.statuses.last
        XCTAssertEqual(status?.phase, .finished(.cancelled))
        try await assertAgentReleased(agent)
        withExtendedLifetime(stream) {}
    }

    func testToolRunsOnceAndArgumentsStayOutOfObservation() async throws {
        let counter = ObservedToolCounter()
        let engine = ObservedScriptEngine([.tool, .text(["done"], "done")])
        let agent = try makeAgent(engine, tools: [BoneAnyAgentTool(ObservedEchoTool(counter: counter))])
        let stream = try await agent.runObservedEvents(request: request, options: .init(totalTimeout: 2))
        var events: [BoneAgentStreamEvent] = []
        for try await envelope in stream { events.append(envelope.event) }
        let count = await counter.count
        XCTAssertEqual(count, 1)
        XCTAssertEqual(engine.invocationCount, 2)
        XCTAssertTrue(events.contains(.toolExecutionStarted(step: 1, callID: "call-1", toolID: "flow.echo")))
        XCTAssertTrue(events.contains(.toolResultReady(step: 1, callID: "call-1", toolID: "flow.echo", isError: false)))
        XCTAssertFalse(String(describing: events).contains("secret-argument"))
    }

    func testFinalDeliveryLimitDoesNotRewriteSuccessOrRepeatTool() async throws {
        let answer = String(repeating: "a", count: 400)
        let normalized = BoneInferenceStreamEvent.completed(.init(response: .init(text: answer), reasoning: nil))
        let final = BoneAgentBoundaryResult(completion: .modelFinished(.text(answer)), steps: 2)
        let limit = max(BoneEventPayloadSize.normalized(normalized),
                        BoneEventPayloadSize.agent(.textDelta(step: 2, text: answer))) + 1
        XCTAssertGreaterThan(BoneEventPayloadSize.agent(.completed(final)), limit)
        let limits = try BoneEventBufferLimits(maximumEventCount: 32,
            maximumQueuedPayloadBytes: limit * 32, maximumEventPayloadBytes: limit)
        let counter = ObservedToolCounter()
        let records = ObservedRecords()
        let engine = ObservedScriptEngine([.tool, .text([answer], answer)])
        let agent = try makeAgent(engine, records: records,
            tools: [BoneAnyAgentTool(ObservedEchoTool(counter: counter))])
        let stream = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 2), buffering: limits)
        var completions = 0
        do {
            for try await envelope in stream { if case .completed = envelope.event { completions += 1 } }
            XCTFail("Expected reserved result to exceed its single-event limit")
        } catch { XCTAssertEqual(error as? BoneEventStreamError, .eventTooLarge) }
        XCTAssertEqual(completions, 0)
        let count = await counter.count
        let status = await agent.currentStatus
        let terminals = await records.events.filter(\.isTerminal)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(engine.invocationCount, 2)
        XCTAssertEqual(status?.phase, .finished(.succeeded))
        XCTAssertEqual(terminals, [.runFinished(.succeeded)])
    }

    func testOldBufferedStreamKeepsItsIdentityAfterNextRunFinishes() async throws {
        let terminal = expectation(description: "first execution completed")
        let records = ObservedRecords()
        let engine = ObservedScriptEngine([.text(["old"], "old"), .text(["new"], "new")])
        let agent = try makeAgent(engine, records: records, terminal: terminal)
        let limits = try BoneEventBufferLimits(maximumEventCount: 2,
            maximumQueuedPayloadBytes: 4_096, maximumEventPayloadBytes: 4_096)
        let old = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 2), buffering: limits)
        await fulfillment(of: [terminal], timeout: 3)
        try await assertAgentReleased(agent)
        let next = try await agent.runObservedEvents(request: request,
            options: .init(totalTimeout: 2), buffering: limits)
        var nextEvents: [BoneAgentObservedEvent] = []
        for try await event in next { nextEvents.append(event) }
        var oldEvents: [BoneAgentObservedEvent] = []
        for try await event in old { oldEvents.append(event) }
        XCTAssertNotEqual(old.runID, next.runID)
        XCTAssertTrue(oldEvents.allSatisfy { $0.runID == old.runID })
        XCTAssertTrue(nextEvents.allSatisfy { $0.runID == next.runID })
        XCTAssertEqual(oldEvents.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(nextEvents.map(\.sequence), [1, 2, 3])
        let status = await agent.currentStatus
        XCTAssertEqual(status?.runID, next.runID)
    }

    func testNestedOrdinaryAgentDoesNotInheritObservedRunIdentityOrFlowPolicy() async throws {
        let innerRecords = ObservedRecords()
        let inner = try makeAgent(BoneScriptedInferenceEngine(script: [.init(text: "inner")]), records: innerRecords)
        let outer = try makeAgent(ObservedScriptEngine([.tool, .text(["done"], "done")]),
            tools: [BoneAnyAgentTool(ObservedNestedTool(agent: inner))])
        let stream = try await outer.runObservedEvents(request: request, options: .init(totalTimeout: 2))
        for try await _ in stream {}
        let innerStatus = await inner.currentStatus
        let outerStatus = await outer.currentStatus
        XCTAssertNotNil(innerStatus)
        XCTAssertEqual(innerStatus?.phase, .finished(.succeeded))
        XCTAssertNotEqual(innerStatus?.runID, stream.runID)
        XCTAssertEqual(outerStatus?.runID, stream.runID)
        let innerTokens = await innerRecords.tokens
        XCTAssertTrue(innerTokens.allSatisfy { $0.runID == innerStatus?.runID })
    }

    func testForwardingOversizeIsFailureRatherThanCancellationWithDeadline() async throws {
        let limits = try BoneEventBufferLimits(maximumEventCount: 4,
            maximumQueuedPayloadBytes: 512, maximumEventPayloadBytes: 128)
        // 规范化载荷 112 字节可接受；Agent 信封 144 字节超限。
        // 重复运行以覆盖发送失败与计时子任务取消的不同调度顺序。
        for iteration in 0..<24 {
            let records = ObservedRecords()
            let terminal = expectation(description: "flow failure \(iteration)")
            let agent = try makeAgent(ObservedScriptEngine([.partial(String(repeating: "a", count: 80))]),
                records: records, terminal: terminal)
            let stream = try await agent.runObservedEvents(request: request,
                options: .init(totalTimeout: 2), buffering: limits)
            var events: [BoneAgentStreamEvent] = []
            do {
                for try await envelope in stream { events.append(envelope.event) }
                XCTFail("Forwarding an oversized event must fail")
            } catch { XCTAssertEqual(error as? BoneEventStreamError, .eventTooLarge) }
            // 通道错误可早于生产任务的异常收口；等待真实终态后再核对执行事实。
            await fulfillment(of: [terminal], timeout: 3)
            XCTAssertEqual(events, [.runStarted])
            let status = await agent.currentStatus
            let tokens = await agent.currentTokens
            let terminals = await records.events.filter(\.isTerminal)
            XCTAssertEqual(status?.phase, .finished(.failed(.inferenceFailed)))
            XCTAssertEqual(tokens?.latestRequest?.state, .failed)
            XCTAssertEqual(terminals, [.runFinished(.failed(.inferenceFailed))])
        }
    }

    private var request: BoneInferenceRequest {
        .init(modelID: "model", messages: [.init(role: .user, content: "hello")])
    }

    private func makeAgent(_ engine: any BoneInferenceEngine,
                           records: ObservedRecords = .init(),
                           tools: [BoneAnyAgentTool] = [],
                           terminal: XCTestExpectation? = nil) throws -> BoneAgent {
        try BoneAgent(inferenceEngine: engine, toolRegistry: .init(tools: tools),
            toolContext: BoneAgentEmptyContext(),
            configuration: .init(maximumSteps: 3, statusSink: .init { value in
                let firstTerminal = await records.record(value)
                if firstTerminal { terminal?.fulfill() }
            }, tokenSink: .init { await records.record($0) }),
            eventSink: .init { await records.record($0) })
    }

    private func assertAgentReleased(_ agent: BoneAgent) async throws {
        // A terminal observer is delivered before the producer's defer releases Run ownership.
        for _ in 0..<200 {
            do {
                _ = try await agent.makeConversation(modelID: "model", bindingID: "fixture")
                return
            } catch BoneAgentError.runAlreadyInProgress {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
        XCTFail("Agent ownership was not released after cancellation")
    }
}

private actor ObservedRecords {
    private(set) var statuses: [BoneAgentStatus] = []
    private(set) var tokens: [BoneAgentTokenSnapshot] = []
    private(set) var events: [BoneAgentEvent] = []
    func record(_ value: BoneAgentStatus) -> Bool {
        statuses.append(value)
        return value.isTerminal && statuses.filter(\.isTerminal).count == 1
    }
    func record(_ value: BoneAgentTokenSnapshot) { tokens.append(value) }
    func record(_ value: BoneAgentEvent) { events.append(value) }
}

private enum ObservedScenario: Sendable {
    case text([String], String)
    case tool
    case missing
    case partial(String)
}

private final class ObservedScriptEngine: BoneInferenceEngine, BoneInferenceFlowControlledEventStreaming, @unchecked Sendable {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .streaming, .toolCalling]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let scenarios: [ObservedScenario]
    private let lock = NSLock()
    private var index = 0

    init(_ scenarios: [ObservedScenario]) { self.scenarios = scenarios }
    var invocationCount: Int { lock.lock(); defer { lock.unlock() }; return index }
    func validateEventFlowControl() throws {}
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "legacy") }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        AsyncThrowingStream { $0.finish(throwing: BoneEventStreamError.flowControlUnavailable) }
    }
    private func takeScenario() -> ObservedScenario {
        lock.lock()
        defer { lock.unlock() }
        defer { index += 1 }
        return scenarios[min(index, scenarios.count - 1)]
    }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions,
                         buffering: BoneEventBufferLimits) -> BoneBoundedEventStream<BoneInferenceStreamEvent> {
        let scenario = takeScenario()
        return BoneInferenceEventStreams.bounded(buffering: buffering, options: options,
            payloadSize: { BoneEventPayloadSize.normalized($0) }) { emit in
            switch scenario {
            case .text(let chunks, let text):
                for chunk in chunks { try await emit(.textDelta(chunk)) }
                try await emit(.completed(.init(response: .init(text: text), reasoning: nil)))
            case .partial(let text):
                try await emit(.textDelta(text))
            case .missing:
                try await emit(.textDelta("partial"))
            case .tool:
                let arguments = Data(#"{"value":"secret-argument"}"#.utf8)
                let turn = try BoneInferenceAssistantTurn(content: [
                    .toolCall(.init(id: "call-1", toolID: "flow.echo", arguments: arguments))
                ])
                try await emit(.toolCallStarted(id: "call-1", toolID: "flow.echo"))
                try await emit(.toolArgumentsDelta(id: "call-1", data: arguments))
                try await emit(.toolCallCompleted(id: "call-1"))
                try await emit(.completed(.init(response: .assistantTurn(turn: turn, finishReason: .toolCalls,
                    usage: nil, refusal: nil, providerContinuation: nil), reasoning: nil)))
            }
        }
    }
}

private actor ObservedToolCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct ObservedEchoTool: BoneAgentTool {
    struct Input: Codable, Sendable { let value: String }
    struct Output: Codable, Sendable { let value: String }
    let counter: ObservedToolCounter
    static var definition: BoneAgentToolDefinition {
        .init(id: "flow.echo", version: "1", title: "Echo", summary: "Fixture",
            wireName: "flow_echo", schemaVersion: 1,
            inputSchema: .object(properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
                                 required: ["value"], additionalProperties: false), impact: .ordinaryPublicRead)
    }
    func execute(input: Input, context: BoneAgentEmptyContext) async throws -> Output {
        await counter.increment()
        return .init(value: input.value)
    }
}

private struct ObservedNestedTool: BoneAgentTool {
    typealias Input = ObservedEchoTool.Input
    typealias Output = ObservedEchoTool.Output
    let agent: BoneAgent
    static var definition: BoneAgentToolDefinition { ObservedEchoTool.definition }
    func execute(input: Input, context: BoneAgentEmptyContext) async throws -> Output {
        _ = try await agent.run(modelID: "inner", messages: [.init(role: .user, content: "nested")])
        return .init(value: input.value)
    }
}
