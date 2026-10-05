import Foundation
import XCTest
@testable import BoneAgentKit

final class ProviderUsageRetentionTests: XCTestCase {
    func testTextUsageSurvivesAllProvidersAndInvocationModes() async throws {
        for kind in [BoneInferenceProviderKind.openAI, .anthropic, .google] {
            let transport = UsageTransport(kind: kind)
            let config = BoneInferenceProviderConfiguration(kind: kind, apiKey: "synthetic",
                baseURL: URL(string: "https://synthetic.invalid")!,
                authenticationMode: kind == .google ? .googleAPIKey : kind == .anthropic ? .anthropicDual : .bearer)
            let engine: any BoneInferenceEngine
            switch kind {
            case .openAI: engine = BoneOpenAIInferenceEngine(configuration: config, transport: transport)
            case .anthropic: engine = BoneAnthropicInferenceEngine(configuration: config, transport: transport)
            default: engine = BoneGeminiInferenceEngine(configuration: config, transport: transport)
            }
            let request = BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "test")])
            let response = try await engine.infer(request: request)
            XCTAssertEqual(response.usage?.inputTokens, 100)
            XCTAssertEqual(response.usage?.outputTokens, 5)
            if kind == .anthropic {
                XCTAssertEqual(response.usage?.cachedInputTokens, 12)
                XCTAssertEqual(response.usage?.cacheCreationInputTokens, 7)
            }
            let streaming = try XCTUnwrap(engine as? any BoneInferenceBufferedStreaming)
            let streamed = try await streaming.inferUsingStream(request: request, options: .init())
            XCTAssertEqual(streamed.usage, response.usage)
            let events = try XCTUnwrap(engine as? any BoneInferenceEventStreaming)
            var final: BoneInferenceResponse?
            for try await event in events.inferenceEvents(request: request, options: .init()) {
                if case .completed(let result) = event { final = result.response }
            }
            XCTAssertEqual(final?.usage, response.usage)
            let recorder = UsageSnapshotRecorder()
            let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
                configuration: try .init(maximumSteps: 1), modelSnapshotSink: .init { await recorder.add($0) })
            _ = try await agent.run(request: request)
            let snapshot = await recorder.value
            XCTAssertEqual(snapshot?.usageByResponse, [response.usage!])
            XCTAssertEqual(snapshot?.totalUsage, response.usage)
            if kind == .openAI {
                let bodies = await transport.bodies
                XCTAssertTrue(bodies.contains { body in
                    guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return false }
                    return (object["stream_options"] as? [String: Bool])?["include_usage"] == true
                })
            }
        }
    }

    func testGatewayCanExplicitlyOmitUnsupportedUsageRequestField() async throws {
        let transport = UsageTransport(kind: .openAI)
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .openAI, apiKey: "synthetic", baseURL: URL(string: "https://synthetic.invalid")!),
            transport: transport, requestsStreamingUsage: false)
        let response = try await engine.inferUsingStream(request: .init(modelID: "model", messages: [.init(role: .user, content: "test")]), options: .init())
        XCTAssertEqual(response.usage?.inputTokens, 100, "Omitting the request flag must not discard returned usage")
        let bodies = await transport.bodies
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodies.first)) as? [String: Any])
        XCTAssertNil(object["stream_options"])
    }

    func testLegacyFinishDecodesWithoutUsageAndNewUsageRoundTrips() throws {
        XCTAssertNil(try JSONDecoder().decode(BoneInferenceFinish.self, from: Data(#"{"text":"old"}"#.utf8)).usage)
        let value = BoneInferenceResponse.finish(.init(text: "new", usage: .init(inputTokens: 100, outputTokens: 5, cachedInputTokens: nil, reasoningTokens: nil)))
        XCTAssertEqual(try JSONDecoder().decode(BoneInferenceResponse.self, from: JSONEncoder().encode(value)), value)
    }
}
private actor UsageSnapshotRecorder {
    var value: BoneAgentRunModelSnapshot?
    func add(_ value: BoneAgentRunModelSnapshot) { self.value = value }
}
private actor UsageTransport: BoneInferenceHTTPTransport {
    let kind: BoneInferenceProviderKind
    var bodies: [Data] = []
    init(kind: BoneInferenceProviderKind) { self.kind = kind }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        let json: String
        switch kind {
        case .openAI: json = #"{"choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5}}"#
        case .anthropic: json = #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","usage":{"input_tokens":100,"output_tokens":5,"cache_read_input_tokens":12,"cache_creation_input_tokens":7}}"#
        default: json = #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":5}}"#
        }
        return .init(statusCode: 200, data: Data(json.utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        bodies.append(request.httpBody ?? Data())
        let values: [String]
        switch kind {
        case .openAI:
            values = [#"{"choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":"stop"}]}"#,
                      #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5}}"#, "[DONE]"]
        case .anthropic:
            values = [#"{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":12,"cache_creation_input_tokens":7}}}"#,
                      #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
                      #"{"type":"content_block_stop","index":0}"#,
                      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}"#,
                      #"{"type":"message_stop"}"#]
        default:
            values = [#"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":5}}"#]
        }
        return .init(statusCode: 200, events: values.map { .init(data: $0) })
    }
}
