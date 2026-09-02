import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaJSONToolCallingCodecTests: XCTestCase {
    func testEncodesDefinitionsAndOutputContract() throws {
        let prompt = try BoneLlamaJSONToolCallingCodec().encode(request: request())

        XCTAssertTrue(prompt.contains("You may call only the tools declared below."))
        XCTAssertTrue(prompt.contains("\"name\":\"echo\""))
        XCTAssertTrue(prompt.contains("\"additionalProperties\":false"))
        XCTAssertTrue(prompt.contains("\"tool_calls\""))
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n"))
    }

    func testEncodesAssistantCallsAndToolResultsForContinuation() throws {
        let arguments = try XCTUnwrap("{\"value\":\"hello\"}".data(using: .utf8))
        let turn = try BoneInferenceAssistantTurn(content: [
            .text("Checking."),
            .toolCall(.init(id: "call-1", toolID: "test.echo", arguments: arguments)),
        ])
        let result = try BoneInferenceToolResult(
            callID: "call-1",
            toolID: "test.echo",
            content: .text("hello"),
            isError: false,
            ordinal: 0
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [
                .init(role: .user, content: "Echo hello"),
                .assistant(turn),
                .toolResults(try .init(results: [result])),
            ],
            availableTools: [Self.tool]
        )

        let prompt = try BoneLlamaJSONToolCallingCodec().encode(request: request)

        XCTAssertTrue(prompt.contains("Checking."))
        XCTAssertTrue(prompt.contains("\"id\":\"call-1\""))
        XCTAssertTrue(prompt.contains("\"name\":\"echo\""))
        XCTAssertTrue(prompt.contains("\"content\":\"hello\""))
        XCTAssertTrue(prompt.contains("\"content_type\":\"text\""))
    }

    func testDecodesMultipleCallsAndMapsWireNamesToStableIDs() throws {
        let output = """
        {"tool_calls":[
          {"id":"call-1","name":"echo","arguments":{"value":"one"}},
          {"id":"call-2","name":"echo","arguments":{"value":"two"}}
        ]}
        """

        let response = try BoneLlamaJSONToolCallingCodec().decode(
            output: output,
            availableTools: [Self.tool]
        )

        guard case let .assistantTurn(turn, reason, usage, refusal, continuation) = response else {
            return XCTFail("Expected assistant turn")
        }
        XCTAssertEqual(reason, .toolCalls)
        XCTAssertNil(usage)
        XCTAssertNil(refusal)
        XCTAssertNil(continuation)
        XCTAssertEqual(turn.toolCalls.map(\.id), ["call-1", "call-2"])
        XCTAssertEqual(turn.toolCalls.map(\.toolID), ["test.echo", "test.echo"])
        XCTAssertEqual(turn.toolCalls.map(\.ordinal), [0, 1])
    }

    func testDecodesPlainTextAsFinish() throws {
        let response = try BoneLlamaJSONToolCallingCodec().decode(
            output: " Answer ",
            availableTools: [Self.tool]
        )
        XCTAssertEqual(response, .finish(.init(text: "Answer")))
    }

    func testRejectsInvalidToolCallingResponses() throws {
        let values = [
            "{\"tool_calls\":[{\"id\":\"1\",\"name\":\"missing\",\"arguments\":{}}]}",
            "{\"tool_calls\":[{\"id\":\"1\",\"name\":\"echo\",\"arguments\":{}}]}",
            "{\"tool_calls\":[{\"id\":\"1\",\"name\":\"echo\",\"arguments\":[]}]}",
            "{\"tool_calls\":[{\"id\":\"1\",\"name\":\"echo\",\"arguments\":{}},{\"id\":\"1\",\"name\":\"echo\",\"arguments\":{}}]}",
            "{\"tool_calls\":[]}",
            "{\"tool_calls\":[",
            "prefix {\"tool_calls\":[{\"id\":\"1\",\"name\":\"echo\",\"arguments\":{}}]}",
        ]

        for value in values {
            XCTAssertThrowsError(try BoneLlamaJSONToolCallingCodec().decode(
                output: value,
                availableTools: [Self.tool]
            ), "Expected rejection for: \(value)") {
                XCTAssertEqual($0 as? BoneLlamaAdapterError, .invalidToolCallingResponse)
            }
        }
    }

    private func request() -> BoneInferenceRequest {
        .init(
            modelID: "model",
            messages: [.init(role: .user, content: "Echo hello")],
            availableTools: [Self.tool]
        )
    }

    private static let tool = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo a value",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: [
                "value": .string(enumValues: [], minimumLength: 1, maximumLength: 100),
            ],
            required: ["value"],
            additionalProperties: false
        )
    )
}
