import Foundation
import XCTest
@testable import BoneAgentKit

final class ReasoningDisclosureTests: XCTestCase {
    func testLegacyRequestDefaultsReasoningDisclosureToHidden() throws {
        let data = Data(#"{"modelID":"m","messages":[{"role":"user","content":"hi"}],"availableTools":[],"generationOptions":{}}"#.utf8)
        let request = try JSONDecoder().decode(BoneInferenceRequest.self, from: data)
        XCTAssertEqual(request.reasoningDisclosure, .hidden)
    }

    func testReasoningDisclosureCodableRoundTripsAllPolicies() throws {
        for policy in BoneInferenceReasoningDisclosure.allCases {
            let encoded = try JSONEncoder().encode(policy)
            XCTAssertEqual(try JSONDecoder().decode(BoneInferenceReasoningDisclosure.self, from: encoded), policy)
        }
    }

    func testReasoningRejectsEmptyText() {
        XCTAssertThrowsError(try BoneInferenceReasoning(kind: .providerReadable, text: ""))
    }

    func testReasoningRejectsContentBeyondByteLimit() {
        let oversized = String(repeating: "a", count: BoneInferenceReasoning.maximumUTF8ByteCount + 1)
        XCTAssertThrowsError(try BoneInferenceReasoning(kind: .summary, text: oversized))
    }

    func testDetailedResultKeepsReasoningSeparateFromAssistantTurn() throws {
        let response = BoneInferenceResponse(text: "final")
        let reasoning = try BoneInferenceReasoning(kind: .summary, text: "summary")
        let result = BoneInferenceDetailedResult(response: response, reasoning: reasoning)
        XCTAssertEqual(result.response, response)
        XCTAssertEqual(result.reasoning, reasoning)
        XCTAssertEqual(result.response.terminalAssistantTurn?.text, "final")
    }

    func testAnthropicReadableThinkingHonorsDisclosureAndNeverLeaksSignature() throws {
        let json: [String: Any] = ["content": [
            ["type": "thinking", "thinking": "可读推理", "signature": "secret-signature"],
            ["type": "redacted_thinking", "data": "secret-redacted"],
            ["type": "text", "text": "结果"],
        ]]
        XCTAssertNil(BoneInferenceReasoningSupport.anthropic(json: json, disclosure: .hidden))
        XCTAssertNil(BoneInferenceReasoningSupport.anthropic(json: json, disclosure: .summary))
        let value = try XCTUnwrap(BoneInferenceReasoningSupport.anthropic(json: json, disclosure: .providerReadable))
        XCTAssertEqual(value.kind, .providerReadable)
        XCTAssertEqual(value.text, "可读推理")
        XCTAssertFalse(value.text.contains("secret"))
    }

    func testAnthropicStreamCollectsThinkingButNotSignature() throws {
        let events = [
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"第一步"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"secret"}}"#),
            event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"第二步"}}"#),
        ]
        let value = try XCTUnwrap(BoneInferenceReasoningSupport.anthropic(events: events, disclosure: .providerReadable))
        XCTAssertEqual(value.text, "第一步第二步")
        XCTAssertNil(BoneInferenceReasoningSupport.anthropic(events: events, disclosure: .summary))
    }

    func testOpenAISeparatesSummaryFromProviderReadableReasoning() throws {
        let message: [String: Any] = [
            "reasoning_content": "原始推理",
            "reasoning_summary": "推理摘要",
        ]
        XCTAssertNil(BoneInferenceReasoningSupport.openAI(message: message, disclosure: .hidden))
        XCTAssertEqual(BoneInferenceReasoningSupport.openAI(message: message, disclosure: .summary)?.text, "推理摘要")
        let readable = try XCTUnwrap(BoneInferenceReasoningSupport.openAI(message: message, disclosure: .providerReadable))
        XCTAssertEqual(readable.kind, .providerReadable)
        XCTAssertEqual(readable.text, "原始推理")
    }

    func testGeminiExposesThoughtTextButNeverThoughtSignature() throws {
        let parts: [[String: Any]] = [
            ["thought": true, "text": "可读思考", "thoughtSignature": "secret"],
            ["text": "最终答案"],
        ]
        XCTAssertNil(BoneInferenceReasoningSupport.gemini(parts: parts, disclosure: .summary))
        let value = try XCTUnwrap(BoneInferenceReasoningSupport.gemini(parts: parts, disclosure: .providerReadable))
        XCTAssertEqual(value.text, "可读思考")
        XCTAssertFalse(value.text.contains("secret"))
    }

    func testGeminiThoughtTextIsExcludedFromFormalAnswer() throws {
        let json: [String: Any] = ["candidates": [[
            "finishReason": "STOP",
            "content": ["parts": [
                ["thought": true, "text": "内部思考", "thoughtSignature": "secret"],
                ["text": "最终答案"],
            ]],
        ]]]
        XCTAssertEqual(try BoneGeminiResponseAggregator.text(from: json), "最终答案")
    }

    func testAnthropicDetailedEngineReturnsReasoningWhileLegacyInferOnlyReturnsResponse() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "thinking", "thinking": "可读推理", "signature": "secret"],
                ["type": "text", "text": "最终结果"],
            ],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 1, "output_tokens": 2],
        ])
        let transport = ReasoningTransport(response: payload)
        let engine = BoneAnthropicInferenceEngine(
            configuration: configuration(kind: .anthropic, authentication: .anthropicDual),
            transport: transport
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "hi")],
            reasoningDisclosure: .providerReadable
        )
        let detailed = try await engine.inferDetailed(request: request)
        XCTAssertEqual(detailed.reasoning?.text, "可读推理")
        XCTAssertEqual(detailed.response.terminalAssistantTurn?.text, "最终结果")
        let legacy = try await engine.infer(request: request)
        XCTAssertEqual(legacy.terminalAssistantTurn?.text, "最终结果")
    }

    func testOversizedOptionalReasoningIsDroppedWithoutFailingResponse() {
        let message: [String: Any] = [
            "reasoning_content": String(repeating: "a", count: BoneInferenceReasoning.maximumUTF8ByteCount + 1),
        ]
        XCTAssertNil(BoneInferenceReasoningSupport.openAI(message: message, disclosure: .providerReadable))
    }

    private func event(_ data: String) -> BoneInferenceEventStreamEvent {
        .init(event: nil, id: nil, data: data)
    }

    private func configuration(
        kind: BoneInferenceProviderKind,
        authentication: BoneInferenceAuthenticationMode
    ) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "test-key",
            baseURL: URL(string: "https://example.com")!,
            authenticationMode: authentication
        )
    }
}

private actor ReasoningTransport: BoneInferenceHTTPTransport {
    let response: Data
    init(response: Data) { self.response = response }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        .init(statusCode: 200, data: response, headers: [:])
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: [], headers: [:])
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }
}
