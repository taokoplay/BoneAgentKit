import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class BoneAgentStreamingTests: XCTestCase {
    func testRunEventsYieldsDeltaBeforeCompletedAndKeepsAgentOwned() async throws {
        let engine = SyntheticAgentStreamingEngine(scenarios: [.text])
        let agent = try makeAgent(engine)
        let stream = try await agent.runEvents(
            request: .init(modelID: "model", messages: [.init(role: .user, content: "hello")]),
            options: .init(totalTimeout: 5)
        )
        let task = Task { () -> [BoneAgentStreamEvent] in
            var values: [BoneAgentStreamEvent] = []
            do {
                for try await value in stream {
                    values.append(value)
                    if case .textDelta = value { await engine.signalDelta() }
                }
            } catch { print("STREAM ERROR", error); XCTFail("unexpected stream error: \(error)") }
            return values
        }
        await engine.waitForDelta()
        do {
            _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "blocked")])
            XCTFail("Agent ownership must remain held until stream completion")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .runAlreadyInProgress)
        }
        let values = await task.value
        XCTAssertEqual(values.first, .runStarted)
        XCTAssertTrue(values.contains(.textDelta(step: 1, text: "hello ")))
        guard case let .completed(result) = values.last else { return XCTFail("missing completed event") }
        XCTAssertEqual(result.completion, .modelFinished(.text("hello world")))
        XCTAssertEqual(result.steps, 1)
        _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "after")])
    }

    func testToolExecutionWaitsForFormalCompletedResponseAndEmitsMetadataOnly() async throws {
        let tool = StreamingEchoTool()
        let engine = SyntheticAgentStreamingEngine(scenarios: [.tool, .finalText("done")])
        let agent = try makeAgent(engine, tools: [BoneAnyAgentTool(tool)])
        let stream = try await agent.runEvents(
            request: .init(modelID: "model", messages: [.init(role: .user, content: "call")]),
            options: .init(totalTimeout: 5)
        )
        var values: [BoneAgentStreamEvent] = []
        for try await value in stream { values.append(value) }
        let execution = await tool.counterValue.count
        XCTAssertEqual(execution, 1)
        guard let modelFinished = values.firstIndex(where: {
            if case .modelToolCallFinished = $0 { return true }
            return false
        }), let executionStarted = values.firstIndex(where: {
            if case .toolExecutionStarted = $0 { return true }
            return false
        }) else { return XCTFail("missing tool events") }
        XCTAssertLessThan(modelFinished, executionStarted)
        XCTAssertTrue(values.contains(.toolResultReady(step: 1, callID: "call-1", toolID: "stream.echo", isError: false)))
        XCTAssertFalse(values.contains { event in
            if case .textDelta(_, let text) = event { return text.contains("secret-argument") }
            return false
        })
        guard case let .completed(result) = values.last else { return XCTFail("missing completion") }
        XCTAssertEqual(result.completion, .modelFinished(.text("done")))
    }

    func testMissingCompletedResponseFailsClosedAndCanBeUsedAgain() async throws {
        let engine = SyntheticAgentStreamingEngine(scenarios: [.missingCompletion, .text])
        let agent = try makeAgent(engine)
        let stream = try await agent.runEvents(
            request: .init(modelID: "model", messages: [.init(role: .user, content: "bad")]),
            options: .init(totalTimeout: 5)
        )
        var values: [BoneAgentStreamEvent] = []
        do {
            for try await value in stream { values.append(value) }
            XCTFail("missing completed must fail")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .inferenceFailed)
        }
        XCTAssertTrue(values.contains(.textDelta(step: 1, text: "partial")))
        let second = try await agent.runEvents(
            request: .init(modelID: "model", messages: [.init(role: .user, content: "after")]),
            options: .init(totalTimeout: 5)
        )
        for try await _ in second {}
    }

    func testRunEventsRejectsBufferedOnlyEngineWithoutStartingRun() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "buffered")])
        let agent = try makeAgent(engine)
        do {
            _ = try await agent.runEvents(
                request: .init(modelID: "model", messages: [.init(role: .user, content: "hello")]),
                options: .init(totalTimeout: 5)
            )
            XCTFail("buffered-only engine must be rejected")
        } catch {
            XCTAssertEqual(error as? BoneAgentError, .unsupportedCapability(.streaming))
        }
        _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "after")])
    }

    private func makeAgent(_ engine: any BoneInferenceEngine, tools: [BoneAnyAgentTool] = []) throws -> BoneAgent {
        try BoneAgent(
            inferenceEngine: engine,
            toolRegistry: .init(tools: tools),
            toolContext: BoneAgentEmptyContext(),
            configuration: .init(maximumSteps: 3)
        )
    }
}

private enum SyntheticStreamingScenario: Sendable { case text, finalText(String), tool, missingCompletion }

private final class SyntheticAgentStreamingEngine: BoneInferenceEngine, BoneInferenceEventStreaming, @unchecked Sendable {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .streaming]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let scenarios: [SyntheticStreamingScenario]
    private let state = SyntheticStreamingState()

    init(scenarios: [SyntheticStreamingScenario]) { self.scenarios = scenarios }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        .init(text: "after")
    }

    func signalDelta() async { await state.signal() }
    func waitForDelta() async { await state.wait() }

    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        let state = self.state
        let scenarios = self.scenarios
        return AsyncThrowingStream { continuation in
            let task = Task {
                let scenario = await state.next(scenarios)
            switch scenario {
                case .text:
                    continuation.yield(.textDelta("hello "))
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    continuation.yield(.completed(.init(response: .init(text: "hello world"), reasoning: nil)))
                    continuation.finish()
                case let .finalText(text):
                    continuation.yield(.textDelta(text))
                    continuation.yield(.completed(.init(response: .init(text: text), reasoning: nil)))
                    continuation.finish()
                case .tool:
                    let turn = try! BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "call-1", toolID: "stream.echo", arguments: Data(#"{"value":"secret-argument"}"#.utf8)))])
                    continuation.yield(.toolCallStarted(id: "call-1", toolID: "stream.echo"))
                    continuation.yield(.toolArgumentsDelta(id: "call-1", data: Data(#"{"value":"secret-argument"}"#.utf8)))
                    continuation.yield(.toolCallCompleted(id: "call-1"))
                    continuation.yield(.completed(.init(response: .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil), reasoning: nil)))
                    continuation.finish()
                case .missingCompletion:
                    continuation.yield(.textDelta("partial"))
                    continuation.finish()
                }
                }
                continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private actor SyntheticStreamingState {
    private var index = 0
    private var deltaSeen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func next(_ scenarios: [SyntheticStreamingScenario]) -> SyntheticStreamingScenario {
        defer { index += 1 }
        return scenarios[min(index, scenarios.count - 1)]
    }
    func signal() {
        deltaSeen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
    func wait() async {
        if deltaSeen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private struct StreamingEchoInput: Codable, Sendable { let value: String }
private struct StreamingEchoOutput: Codable, Sendable { let ok: Bool }
private struct StreamingEchoTool: BoneAgentTool {
    typealias Input = StreamingEchoInput
    typealias Output = StreamingEchoOutput
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(
        id: "stream.echo", version: "1", title: "Echo", summary: "Echo",
        wireName: "stream_echo", schemaVersion: 1,
        inputSchema: .object(properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)], required: ["value"], additionalProperties: false),
        impact: .ordinaryPublicRead
    )
    var definition: BoneAgentToolDefinition { Self.definition }
    var counter = StreamingEchoCounter()
    func execute(input: Input, context: Context) async throws -> Output {
        await counter.increment()
        return .init(ok: true)
    }
}
private actor StreamingEchoCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
private extension StreamingEchoTool {
    var counterValue: StreamingEchoCounter { counter }
}
