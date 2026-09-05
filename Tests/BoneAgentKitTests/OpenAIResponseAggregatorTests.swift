import Foundation
import XCTest
@testable import BoneAgentKit

final class OpenAIResponseAggregatorTests: XCTestCase {
    func testContentFilterTextIsNotSuccessful() {
        let json: [String: Any] = ["choices": [["finish_reason": "content_filter", "message": ["content": "partial"]]]]
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: json)) {
            XCTAssertEqual($0 as? BoneInferenceTransportError, .invalidResponse)
        }
    }

    func testMissingFinishReasonAndUnframedDONEIsNotSuccessful() {
        XCTAssertThrowsError(try {
            var framer = BoneInferenceEventStreamFramer(maximumBytes: 4096)
            let input = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\ndata: [DONE]"
            var events = try framer.append(Data(input.utf8))
            events += try framer.finish()
            return try BoneOpenAIResponseAggregator.streamingText(from: events)
        }()) {
            XCTAssertEqual($0 as? BoneInferenceTransportError, .invalidResponse)
        }
    }

    private func chunk(_ choice: [String: Any]) throws -> BoneInferenceEventStreamEvent {
        let data = try JSONSerialization.data(withJSONObject: ["choices": [choice]])
        return .init(data: String(decoding: data, as: UTF8.self))
    }

    func testTerminalReasonMatrixIsConsistentForBothModes() throws {
        for strict in [false, true] {
            for reason in ["stop", "length", "content_filter", "refusal", "tool_calls", "function_call", "unknown", ""] {
                let json: [String: Any] = ["choices": [["index": 0, "finish_reason": reason, "message": ["content": "ok"]]]]
                let events = [try chunk(["index": 0, "delta": ["content": "ok"], "finish_reason": reason]), .init(data: "[DONE]")]
                if reason == "stop" {
                    XCTAssertEqual(try BoneOpenAIResponseAggregator.nonStreamingText(from: json, requiringSingleCompletedChoice: strict), "ok")
                    XCTAssertEqual(try BoneOpenAIResponseAggregator.streamingText(from: events, requiringSingleCompletedChoice: strict), "ok")
                } else {
                    let expected: BoneInferenceTransportError = reason == "length" ? .outputTruncated : .invalidResponse
                    XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: json, requiringSingleCompletedChoice: strict)) {
                        XCTAssertEqual($0 as? BoneInferenceTransportError, expected, reason)
                    }
                    XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: events, requiringSingleCompletedChoice: strict)) {
                        XCTAssertEqual($0 as? BoneInferenceTransportError, expected, reason)
                    }
                }
            }
        }
    }

    func testMissingNullOrMalformedFinishReasonCannotSucceed() throws {
        for reason in [nil, NSNull(), 42] as [Any?] {
            var choice: [String: Any] = ["message": ["content": "ok"], "delta": ["content": "ok"]]
            choice["finish_reason"] = reason
            XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: ["choices": [choice]]))
            XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: [try chunk(choice), .init(data: "[DONE]")]))
        }
    }

    func testDuplicateDONEDataAfterDONEAndMissingDONEAreRejected() throws {
        let stop = try chunk(["delta": ["content": "ok"], "finish_reason": "stop"])
        let done = BoneInferenceEventStreamEvent(data: "[DONE]")
        for events in [[stop, done, done], [stop, done, stop], [stop], [done], [stop, stop, done]] {
            XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: events)) {
                XCTAssertEqual($0 as? BoneInferenceTransportError, .invalidResponse)
            }
        }
    }

    func testMultiChoiceAndInvalidIndicesCannotBeMergedOrSelected() throws {
        let choice: [String: Any] = ["index": 0, "finish_reason": "stop", "message": ["content": "ok"], "delta": ["content": "ok"]]
        let json: [String: Any] = ["choices": [choice, choice]]
        let event = BoneInferenceEventStreamEvent(data: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: json))
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: [event, .init(data: "[DONE]")]))
        for index in [1, -1, "0"] as [Any] {
            var invalid = choice
            invalid["index"] = index
            XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: ["choices": [invalid]]))
            XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: [try chunk(invalid), .init(data: "[DONE]")]))
        }
        let first = try chunk(["index": 0, "delta": ["content": "first"]])
        let other = try chunk(["index": 1, "delta": ["content": "second"], "finish_reason": "stop"])
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: [first, other, .init(data: "[DONE]")]))
    }

    func testExplicitRefusalCannotSucceedEvenWithStop() throws {
        let json: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": "partial", "refusal": "refused"]]]]
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.nonStreamingText(from: json))
        let event = try chunk(["finish_reason": "stop", "delta": ["content": "partial", "refusal": "refused"]])
        XCTAssertThrowsError(try BoneOpenAIResponseAggregator.streamingText(from: [event, .init(data: "[DONE]")]))
    }

    func testFragmentedTextNullReasonUsageAndNullRefusalRemainCompatible() throws {
        let events = [
            try chunk(["index": 0, "delta": ["role": "assistant"], "finish_reason": NSNull()]),
            try chunk(["index": 0, "delta": ["content": "你", "refusal": NSNull()]]),
            try chunk(["index": 0, "delta": ["content": "好"], "finish_reason": "stop"]),
            BoneInferenceEventStreamEvent(data: #"{"choices":[],"usage":{"completion_tokens":2}}"#),
            .init(data: "[DONE]")
        ]
        XCTAssertEqual(try BoneOpenAIResponseAggregator.streamingText(from: events), "你好")
        let json: [String: Any] = ["choices": [["finish_reason": "stop", "message": ["content": [["type": "text", "text": "你好"]], "refusal": NSNull()]]]]
        XCTAssertEqual(try BoneOpenAIResponseAggregator.nonStreamingText(from: json), "你好")
    }
}
