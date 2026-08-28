import Foundation
import XCTest
@testable import BoneAgentKit

/// Anthropic 聚合器在 stop_reason 显示输出预算耗尽时必须显式失败，禁止静默交付半截正文。
final class BoneAnthropicResponseAggregatorTests: XCTestCase {
    private func event(_ name: String, _ payload: String) -> BoneInferenceEventStreamEvent {
        BoneInferenceEventStreamEvent(event: name, id: nil, data: payload)
    }

    func testStreamingMaxTokensStopReasonThrowsOutputTruncated() {
        let partialText = "{\\\"characters\\\":["
        let events = [
            event(
                "message_start",
                "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\"}}"
            ),
            event(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"\(partialText)\"}}"
            ),
            event(
                "message_delta",
                "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\",\"stop_sequence\":null}}"
            ),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertThrowsError(try BoneAnthropicResponseAggregator.streamingText(from: events)) { error in
            XCTAssertEqual(error as? BoneInferenceTransportError, .outputTruncated)
        }
    }

    func testStreamingEndTurnStillDeliversText() throws {
        let events = [
            event(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"{}\"}}"
            ),
            event(
                "message_delta",
                "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\",\"stop_sequence\":null}}"
            ),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.streamingText(from: events), "{}")
    }

    func testStreamingMissingStopReasonKeepsLegacyLenientBehavior() throws {
        let events = [
            event(
                "content_block_delta",
                "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}"
            ),
            event("message_stop", "{\"type\":\"message_stop\"}"),
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.streamingText(from: events), "ok")
    }

    func testNonStreamingMaxTokensTopLevelStopReasonThrowsOutputTruncated() {
        let json: [String: Any] = [
            "stop_reason": "max_tokens",
            "content": [[
                "type": "text",
                "text": "{\"characters\":[",
            ]],
        ]
        XCTAssertThrowsError(try BoneAnthropicResponseAggregator.nonStreamingText(from: json)) { error in
            XCTAssertEqual(error as? BoneInferenceTransportError, .outputTruncated)
        }
    }

    func testNonStreamingEndTurnDeliversText() throws {
        let json: [String: Any] = [
            "stop_reason": "end_turn",
            "content": [["type": "text", "text": "{}"]],
        ]
        XCTAssertEqual(try BoneAnthropicResponseAggregator.nonStreamingText(from: json), "{}")
    }
}
