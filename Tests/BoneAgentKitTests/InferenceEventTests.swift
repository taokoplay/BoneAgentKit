import Foundation
import XCTest
@testable import BoneAgentKit

final class InferenceEventTests: XCTestCase {
    func testAnthropicEventMapperHonorsDisclosureAndHidesSignature() throws {
        var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .providerReadable)
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)), [.reasoningStarted(kind: .providerReadable)])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"分析"}}"#)), [.reasoningDelta("分析")])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"secret"}}"#)), [])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_stop","index":0}"#)), [.reasoningCompleted])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#)), [])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"结果"}}"#)), [.textDelta("结果")])
    }

    func testHiddenDisclosureNeverEmitsReasoningEvents() throws {
        var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .hidden)
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)), [])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"secret"}}"#)), [])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_stop","index":0}"#)), [])
    }

    func testSummaryDoesNotTreatAnthropicThinkingAsSummary() throws {
        var mapper = BoneAnthropicNormalizedEventMapper(disclosure: .summary)
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#)), [])
        XCTAssertEqual(try mapper.consume(event(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"raw"}}"#)), [])
    }

    func testMessageDecodingRejectsMissingPayload() {
        assertMessageDecodingFails(#"{"role":"user"}"#)
    }

    func testMessageDecodingRejectsMultiplePayloads() throws {
        let turn = try BoneInferenceAssistantTurn(content: [.text("answer")])
        let assistant = try encodedObject(BoneInferenceMessage.assistant(turn))
        let assistantTurn = try XCTUnwrap(assistant["assistantTurn"])
        let data = try JSONSerialization.data(withJSONObject: [
            "role": "assistant",
            "content": "conflict",
            "assistantTurn": assistantTurn,
        ])
        XCTAssertThrowsError(try JSONDecoder().decode(BoneInferenceMessage.self, from: data))
    }

    func testMessageDecodingRejectsRolePayloadConflict() {
        assertMessageDecodingFails(#"{"role":"tool","content":"not a tool result"}"#)
        assertMessageDecodingFails(#"{"role":"user","toolResult":{"callID":"call","toolID":"tool","content":{"text":{"_0":"ok"}},"isError":false,"ordinal":0}}"#)
    }

    func testMessageDecodingRejectsWrongPayloadTypeAndMissingRole() {
        assertMessageDecodingFails(#"{"role":"user","content":42}"#)
        assertMessageDecodingFails(#"{"content":"missing role"}"#)
    }

    func testMessageDecodingKeepsLegacyTextMessagesCompatible() throws {
        for role in ["user", "assistant"] {
            let data = Data(#"{"role":"\#(role)","content":"legacy text"}"#.utf8)
            let message = try JSONDecoder().decode(BoneInferenceMessage.self, from: data)
            XCTAssertEqual(message.content, "legacy text")
            XCTAssertEqual(message.role.rawValue, role)
        }
    }

    private func assertMessageDecodingFails(
        _ json: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try JSONDecoder().decode(BoneInferenceMessage.self, from: Data(json.utf8)),
            file: file,
            line: line
        )
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func event(_ data: String) -> BoneInferenceEventStreamEvent { .init(data: data) }
}
