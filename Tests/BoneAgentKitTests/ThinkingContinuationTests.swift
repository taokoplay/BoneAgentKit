import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ThinkingContinuationTests: XCTestCase {
    private let secret = "private-thinking-canary"
    private func config(_ kind: BoneInferenceProviderKind, host: String = "https://example.com") -> BoneInferenceProviderConfiguration {
        .init(kind: kind, apiKey: "fixture", baseURL: URL(string: host)!)
    }
    private func tool() throws -> BoneAgentToolDefinition {
        .init(id: "lookup", version: "1.0.0", title: "Lookup", summary: "Look up", wireName: "lookup", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false))
    }
    private func request(_ tools: [BoneAgentToolDefinition] = [], messages: [BoneInferenceMessage]? = nil,
                         continuation: BoneInferenceProviderContinuation? = nil) -> BoneInferenceRequest {
        .init(modelID: "m", messages: messages ?? [.init(role: .user, content: "hello")], availableTools: tools,
              providerContinuation: continuation, reasoningDisclosure: .hidden)
    }
    private var openAIProfile: BoneInferenceReasoningProfile {
        .init(wireFormat: .thinkingType, continuation: .reasoningContent)
    }
    private var anthropicProfile: BoneInferenceReasoningProfile {
        .init(wireFormat: .anthropicBudget, continuation: .anthropicThinking)
    }
    private func nextRequest(_ response: BoneInferenceResponse, tools: [BoneAgentToolDefinition]) throws -> BoneInferenceRequest {
        let turn = try XCTUnwrap(response.terminalAssistantTurn)
        return request(tools, messages: [
            .init(role: .user, content: "hello"), .assistant(turn),
            try .toolResult(callID: "call", toolID: "lookup", result: Data("{}".utf8))
        ], continuation: response.providerContinuationValue)
    }

    func testOpenAIToolRoundTripRetainsPrivateReasoningWithoutDisclosure() async throws {
        let transport = ThinkingRoundTripTransport([
            #"{"choices":[{"index":0,"message":{"content":"checking","reasoning_content":"private-thinking-canary","tool_calls":[{"id":"call","type":"function","function":{"name":"lookup","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[{"index":0,"message":{"content":"done","reasoning_content":"final private thought"},"finish_reason":"stop"}]}"#
        ])
        let engine = BoneOpenAIInferenceEngine(configuration: config(.custom), transport: transport,
                                              modelReasoningProfiles: ["m": openAIProfile])
        let tools = [try tool()]
        let first = try await engine.inferDetailed(request: request(tools))
        XCTAssertNil(first.reasoning)
        XCTAssertFalse(first.response.terminalAssistantTurn!.text!.contains(secret))
        let second = try await engine.inferDetailed(request: nextRequest(first.response, tools: tools))
        XCTAssertNil(second.reasoning)
        let bodies = await transport.bodies
        let messages = try XCTUnwrap(bodies.last?["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, secret)
        let envelope = try BoneThinkingContinuation.decode(XCTUnwrap(second.response.providerContinuationValue), configuration: config(.custom), profiles: ["m": openAIProfile])
        XCTAssertEqual(envelope.entries.count, 2)
    }

    func testAnthropicRetainsOriginalBlockOrderAndRedactedContent() async throws {
        let json = #"{"content":[{"type":"thinking","thinking":"private-thinking-canary","signature":"opaque-signature"},{"type":"text","text":"checking"},{"type":"redacted_thinking","data":"opaque-redacted"},{"type":"tool_use","id":"call","name":"lookup","input":{}}],"stop_reason":"tool_use"}"#
        let transport = ThinkingRoundTripTransport([json, #"{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}"#])
        let engine = BoneAnthropicInferenceEngine(configuration: config(.anthropic), transport: transport,
                                                 modelReasoningProfiles: ["m": anthropicProfile])
        let tools = [try tool()]
        let first = try await engine.inferDetailed(request: request(tools))
        XCTAssertNil(first.reasoning)
        _ = try await engine.infer(request: nextRequest(first.response, tools: tools))
        let bodies = await transport.bodies
        let messages = try XCTUnwrap(bodies.last?["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.compactMap { $0["type"] as? String }, ["thinking", "text", "redacted_thinking", "tool_use"])
        XCTAssertEqual(blocks[0]["signature"] as? String, "opaque-signature")
        XCTAssertEqual(blocks[2]["data"] as? String, "opaque-redacted")
    }

    func testContinuationFailsClosedForEndpointModelAndModifiedTurn() async throws {
        let transport = ThinkingRoundTripTransport([#"{"choices":[{"message":{"content":"answer","reasoning_content":"private-thinking-canary"},"finish_reason":"stop"}]}"#])
        let engine = BoneOpenAIInferenceEngine(configuration: config(.custom), transport: transport, modelReasoningProfiles: ["m": openAIProfile])
        let response = try await engine.infer(request: request())
        let continuation = try XCTUnwrap(response.providerContinuationValue)
        let history: [BoneInferenceMessage] = [.init(role: .user, content: "hello"), .assistant(try XCTUnwrap(response.terminalAssistantTurn))]
        let changedHost = BoneOpenAIInferenceEngine(configuration: config(.custom, host: "https://other.example.com"), transport: transport, modelReasoningProfiles: ["m": openAIProfile])
        XCTAssertThrowsError(try changedHost.resolvedCapabilities(for: request(messages: history, continuation: continuation), invocation: .nonStreaming))
        let changedModel = BoneInferenceRequest(modelID: "other", messages: history, providerContinuation: continuation)
        XCTAssertThrowsError(try engine.resolvedCapabilities(for: changedModel, invocation: .nonStreaming))
        let changed = [history[0], BoneInferenceMessage(role: .assistant, content: "modified")]
        XCTAssertThrowsError(try engine.resolvedCapabilities(for: request(messages: changed, continuation: continuation), invocation: .nonStreaming))
        XCTAssertEqual(try engine.rebindContextContinuation(continuation, from: history, to: history), continuation)
        XCTAssertNil(try engine.rebindContextContinuation(continuation, from: history, to: [.init(role: .user, content: "new")]))
        XCTAssertThrowsError(try engine.rebindContextContinuation(continuation, from: history, to: changed))
    }

    func testStreamPayloadReconstructionAndBounds() throws {
        func event(_ json: String) -> BoneInferenceEventStreamEvent { .init(data: json) }
        let events = [
            event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"end"}}"#),
            event(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            event(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}"#)
        ]
        let data = try XCTUnwrap(BoneThinkingContinuation.anthropicPayload(events: events))
        let blocks = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(blocks[0]["signature"] as? String, "sig-end")
        XCTAssertEqual(blocks[1]["text"] as? String, "answer")
        XCTAssertThrowsError(try BoneThinkingContinuation.openAIPayload(json: ["choices": [["message": ["reasoning_content": String(repeating: "x", count: 300000)]]]]))
        XCTAssertThrowsError(try BoneThinkingContinuation.anthropicPayload(json: ["content": [["type": "thinking", "thinking": "unsigned"]]]))
    }

    func testLegacyEngineDoesNotRetainPrivatePayload() async throws {
        let transport = ThinkingRoundTripTransport([#"{"choices":[{"message":{"content":"answer","reasoning_content":"private-thinking-canary"},"finish_reason":"stop"}]}"#])
        let engine = BoneOpenAIInferenceEngine(configuration: config(.custom), transport: transport)
        let result = try await engine.inferDetailed(request: request())
        XCTAssertNil(result.reasoning)
        XCTAssertNil(result.response.providerContinuationValue)
    }

    func testAnthropicStreamCanonicalizesToolArgumentsForContinuation() throws {
        let events: [BoneInferenceEventStreamEvent] = [
            .init(data: #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            .init(data: #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{ \"b\": 2, \"a\": 1 }"}}"#),
            .init(data: #"{"type":"content_block_stop","index":0}"#),
            .init(data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#),
            .init(data: #"{"type":"message_stop"}"#)
        ]
        let response = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: [tool()])
        guard case let .assistantTurn(turn, reason, _, _, _) = response else { return XCTFail("expected assistant turn") }
        XCTAssertEqual(reason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.first?.arguments, Data(#"{"a":1,"b":2}"#.utf8))
    }

    func testAnthropicStreamingRoundTripRetainsThinkingBlocksForToolLoop() async throws {
        let firstEvents: [BoneInferenceEventStreamEvent] = [
            .init(data: #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            .init(data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private"}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#),
            .init(data: #"{"type":"content_block_stop","index":0}"#),
            .init(data: #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"checking"}}"#),
            .init(data: #"{"type":"content_block_stop","index":1}"#),
            .init(data: #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"call","name":"lookup","input":{}}}"#),
            .init(data: #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{ \"b\": 2, \"a\": 1 }"}}"#),
            .init(data: #"{"type":"content_block_stop","index":2}"#),
            .init(data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":1}}"#),
            .init(data: #"{"type":"message_stop"}"#)
        ]
        let secondEvents: [BoneInferenceEventStreamEvent] = [
            .init(data: #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            .init(data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"final"}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig2"}}"#),
            .init(data: #"{"type":"content_block_stop","index":0}"#),
            .init(data: #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":"done"}}"#),
            .init(data: #"{"type":"content_block_stop","index":1}"#),
            .init(data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            .init(data: #"{"type":"message_stop"}"#)
        ]
        let transport = ThinkingRoundTripTransport([], streamEvents: [firstEvents, secondEvents])
        let engine = BoneAnthropicInferenceEngine(configuration: config(.anthropic), transport: transport,
                                                 modelReasoningProfiles: ["m": anthropicProfile])
        let tools = [try tool()]
        let first = try await engine.inferDetailedUsingStream(request: request(tools), options: .init())
        XCTAssertEqual(first.response.terminalAssistantTurn?.toolCalls.first?.arguments, Data(#"{"a":1,"b":2}"#.utf8))
        let second = try await engine.inferDetailedUsingStream(request: nextRequest(first.response, tools: tools), options: .init())
        XCTAssertEqual(second.response.terminalAssistantTurn?.text, "done")
        let bodies = await transport.bodies
        let messages = try XCTUnwrap(bodies.last? ["messages"] as? [[String: Any]])
        let replayedBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(replayedBlocks.compactMap { $0["type"] as? String }, ["thinking", "text", "tool_use"])
        XCTAssertEqual((replayedBlocks[2]["input"] as? [String: Any])?["a"] as? Int, 1)
    }

    func testAnthropicStrictStreamRejectsThinkingDeltaAfterBlockStop() throws {
        let events: [BoneInferenceEventStreamEvent] = [
            .init(data: #"{"type":"message_start","message":{"usage":{"input_tokens":1,"output_tokens":0}}}"#),
            .init(data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"before"}}"#),
            .init(data: #"{"type":"content_block_stop","index":0}"#),
            .init(data: #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"after"}}"#),
            .init(data: #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#),
            .init(data: #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"answer"}}"#),
            .init(data: #"{"type":"content_block_stop","index":1}"#),
            .init(data: #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#),
            .init(data: #"{"type":"message_stop"}"#)
        ]
        XCTAssertThrowsError(try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: []))
    }

    func testContinuationStructuredOutputFailsBeforeTransport() async throws {
        let transport = ThinkingRoundTripTransport([#"{"choices":[{"message":{"content":"answer","reasoning_content":"private"},"finish_reason":"stop"}]}"#])
        let engine = BoneOpenAIInferenceEngine(configuration: config(.custom), transport: transport,
                                              modelReasoningProfiles: ["m": openAIProfile])
        let first = try await engine.infer(request: request())
        let structured = BoneInferenceRequest(modelID: "m", messages: [.init(role: .user, content: "hello"), .assistant(try XCTUnwrap(first.terminalAssistantTurn))],
            responseFormat: .jsonObject(fallback: .requireNative), providerContinuation: first.providerContinuationValue)
        XCTAssertThrowsError(try engine.resolvedCapabilities(for: structured, invocation: .nonStreaming))
        let sendCount = await transport.sendCount
        XCTAssertEqual(sendCount, 1)
    }
}

private extension BoneInferenceResponse {
    var providerContinuationValue: BoneInferenceProviderContinuation? {
        if case let .assistantTurn(_, _, _, _, value) = self { return value }
        return nil
    }
}

private actor ThinkingRoundTripTransport: BoneInferenceHTTPTransport {
    private var responses: [String]
    private var streamResponses: [[BoneInferenceEventStreamEvent]]
    private var bodyData: [Data] = []
    private(set) var sendCount = 0
    var bodies: [[String: Any]] { bodyData.compactMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } }
    init(_ responses: [String], streamEvents: [[BoneInferenceEventStreamEvent]] = []) {
        self.responses = responses
        self.streamResponses = streamEvents
    }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sendCount += 1
        bodyData.append(request.httpBody ?? Data())
        guard !responses.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return .init(statusCode: 200, data: Data(responses.removeFirst().utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        bodyData.append(request.httpBody ?? Data())
        guard !streamResponses.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return .init(statusCode: 200, events: streamResponses.removeFirst())
    }
}
