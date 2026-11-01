import Foundation
import XCTest
@testable import BoneAgentKit

/// Anthropic 普通文本在预算耗尽时保留已生成内容，并显式标记 length；Tool/结构化路径另行严格拒绝。
final class BoneAnthropicResponseAggregatorTests: XCTestCase {
    private func event(_ name: String, _ payload: String) -> BoneInferenceEventStreamEvent {
        BoneInferenceEventStreamEvent(event: name, id: nil, data: payload)
    }

    func testStreamingMaxTokensStopReasonReturnsPartialTextAndLength() throws {
        let partialJSON = "{\\\"characters\\\":["
        let events = [
            event("message_start", "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}"),
            event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(partialJSON)\"}}"),
            event("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\",\"stop_sequence\":null}}"),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        let result = try BoneAnthropicResponseAggregator.streamingResult(from: events)
        XCTAssertEqual(result.text, "{\"characters\":[")
        XCTAssertEqual(result.finishReason, .length)
    }

    func testStreamingTextCompatibilityAPIReturnsPartialTextOnMaxTokens() throws {
        let events = [
            event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}"),
            event("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}"),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.streamingText(from: events), "partial")
    }

    func testStreamingEndTurnStillDeliversText() throws {
        let events = [
            event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"{}\"}}"),
            event("message_delta", "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null}}"),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.streamingText(from: events), "{}")
    }

    func testStreamingMissingStopReasonKeepsLegacyLenientBehavior() throws {
        let events = [
            event("content_block_delta", "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}"),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.streamingText(from: events), "ok")
    }

    func testNonStreamingMaxTokensReturnsPartialTextAndLength() throws {
        let json: [String: Any] = [
            "stop_reason": "max_tokens",
            "content": [["type": "text", "text": "partial"]],
        ]
        let result = try BoneAnthropicResponseAggregator.nonStreamingResult(from: json)
        XCTAssertEqual(result.text, "partial")
        XCTAssertEqual(result.finishReason, .length)
    }

    func testNonStreamingEndTurnDeliversText() throws {
        let json: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "{}"]],
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.nonStreamingText(from: json), "{}")
    }
}
