import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class Alpha15RegressionTests: XCTestCase {
    private let tool = BoneAgentToolDefinition(id: "probe", version: "1", title: "Probe", summary: "Probe", wireName: "probe", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false))
    private func event(_ text: String) -> BoneInferenceEventStreamEvent { .init(data: text) }

    func testOpenAIRejectsParametersAfterSemanticEndButAllowsUsageTrailer() throws {
        let start = event(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","type":"function","function":{"name":"probe","arguments":"{"}}]},"finish_reason":null}]}"#)
        let finish = event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#)
        let late = event(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}"#)
        XCTAssertThrowsError(try BoneOpenAIToolStreamAggregator.aggregate(events: [start, finish, late, event("[DONE]")], definitions: [tool]))
        let valid = try BoneOpenAIToolStreamAggregator.aggregate(events: [start, late, finish, event(#"{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2}}"#), event("[DONE]")], definitions: [tool])
        guard case .assistantTurn = valid else { return XCTFail("Expected valid tool turn") }
    }

    func testAnthropicRejectsParametersAfterSemanticEnd() throws {
        let start = event(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c","name":"probe","input":{}}}"#)
        let finish = event(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#)
        let late = event(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#)
        let close = event(#"{"type":"content_block_stop","index":0}"#)
        let stop = event(#"{"type":"message_stop"}"#)
        XCTAssertThrowsError(try BoneAnthropicToolStreamAggregator.aggregate(events: [start, finish, late, close, stop], definitions: [tool]))
        XCTAssertNoThrow(try BoneAnthropicToolStreamAggregator.aggregate(events: [start, late, close, finish, stop], definitions: [tool]))
    }

    func testRealProviderAgentRejectsLateToolWithZeroExecutions() async throws {
        let openAI = [
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c","type":"function","function":{"name":"probe","arguments":"{"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"}"}}]},"finish_reason":null}]}"#, "[DONE]"
        ]
        let anthropic = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c","name":"probe","input":{}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
            #"{"type":"content_block_stop","index":0}"#, #"{"type":"message_stop"}"#
        ]
        for isAnthropic in [false, true] {
            let transport = LateToolTransport(events: (isAnthropic ? anthropic : openAI).map { .init(data: $0) })
            let config = BoneInferenceProviderConfiguration(kind: isAnthropic ? .anthropic : .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!, authenticationMode: isAnthropic ? .anthropicDual : .bearer)
            let engine: any BoneInferenceEngine = isAnthropic
                ? BoneAnthropicInferenceEngine(configuration: config, transport: transport)
                : BoneOpenAIInferenceEngine(configuration: config, transport: transport)
            let counter = ToolCounter()
            let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: [BoneAnyAgentTool(CountedProbe(counter: counter))]), toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 2, inferenceMode: .bufferedStreaming(.init(totalTimeout: 10))))
            do {
                _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
                XCTFail("Expected invalid sequence")
            } catch { XCTAssertEqual(error as? BoneAgentError, .inferenceFailed) }
            let calls = await counter.count
            let sends = await transport.sends
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(sends, 1)
        }
    }

    func testNestedInvalidDiagnosticsAndStopAlias() {
        func summary(_ json: String, _ wire: BoneInferenceResponseDiagnostic.WireProtocol) -> BoneInferenceResponseDiagnostic {
            .capture(.init(statusCode: 200, data: Data(json.utf8)), wire: wire)
        }
        XCTAssertEqual(summary(#"{"usage":{"completion_tokens_details":false}}"#, .openAI).reasoningTokens, .invalid)
        XCTAssertEqual(summary(#"{"candidates":[{"content":{"parts":[{"functionCall":false}]}}]}"#, .gemini).toolCount, .invalid)
        XCTAssertEqual(summary(#"{"content":[{"type":123}]}"#, .anthropic).toolCount, .invalid)
        XCTAssertEqual(summary(#"{"stop_reason":"max_output_tokens"}"#, .anthropic).stop, .length)
        XCTAssertEqual(summary(#"{"usage":{}}"#, .openAI).reasoningTokens, .unknown)
        XCTAssertEqual(summary(#"{"usage":{"completion_tokens_details":{}}}"#, .openAI).reasoningTokens, .unknown)
        XCTAssertEqual(summary(#"{"usage":{"completion_tokens_details":{"reasoning_tokens":0}}}"#, .openAI).reasoningTokens, .value(0))
        XCTAssertEqual(summary(#"{"usage":{"completion_tokens_details":{"reasoning_tokens":false}}}"#, .openAI).reasoningTokens, .invalid)
        XCTAssertEqual(summary(#"{"candidates":[{"content":{"parts":[{"text":"ok"}]}}]}"#, .gemini).toolCount, .value(0))
    }

    func testAgentPreservesTransportCancellation() async throws {
        let recorder = CancellationRecorder()
        let agent = BoneAgent(inferenceEngine: CancelledEngine(), toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 1), eventSink: .init { await recorder.append($0) })
        do { _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "hi")]); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await recorder.events
        XCTAssertEqual(events.last, .runFinished(.cancelled))
        XCTAssertFalse(events.contains(.runFinished(.failed(.inferenceFailed))))
    }
}
private actor CancellationRecorder {
    var events: [BoneAgentEvent] = []
    func append(_ event: BoneAgentEvent) { events.append(event) }
}
private struct CancelledEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { throw BoneInferenceTransportError.cancelled }
}

private actor ToolCounter {
    var count = 0
    func increment() { count += 1 }
}
private struct CountedProbe: BoneAgentTool {
    struct Input: Codable, Sendable {}
    struct Output: Codable, Sendable {}
    typealias Context = BoneAgentEmptyContext
    let counter: ToolCounter
    static let definition = BoneAgentToolDefinition(id: "probe", version: "1", title: "Probe", summary: "Probe", wireName: "probe", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false))
    func execute(input: Input, context: Context) async throws -> Output { await counter.increment(); return .init() }
}
private actor LateToolTransport: BoneInferenceHTTPTransport {
    let events: [BoneInferenceEventStreamEvent]
    var sends = 0
    init(events: [BoneInferenceEventStreamEvent]) { self.events = events }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { sends += 1; throw BoneInferenceTransportError.invalidResponse }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { sends += 1; return .init(statusCode: 200, events: events) }
}
