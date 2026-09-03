import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaConstrainedJSONToolEnvelopeCodecTests: XCTestCase {
    func testDecodesFinalAndToolCallEnvelopes() throws {
        let codec = BoneLlamaConstrainedJSONToolEnvelopeCodec()

        XCTAssertEqual(
            try codec.decode(
                output: #"{"type":"final","content":"Answer"}"#,
                availableTools: [Self.echoTool]
            ),
            .finish(.init(text: "Answer"))
        )

        let response = try codec.decode(
            output: #"{"type":"tool_calls","tool_calls":[{"id":"call-1","name":"echo","arguments":{"value":"hello"}}]}"#,
            availableTools: [Self.echoTool]
        )
        guard case let .assistantTurn(turn, reason, _, _, _) = response else {
            return XCTFail("Expected tool turn")
        }
        XCTAssertEqual(reason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.map(\.toolID), ["test.echo"])
    }

    func testRejectsUnknownToolsInvalidArgumentsDuplicateIDsAndMixedFields() throws {
        let codec = BoneLlamaConstrainedJSONToolEnvelopeCodec()
        let invalid = [
            #"{"type":"tool_calls","tool_calls":[{"id":"1","name":"missing","arguments":{}}]}"#,
            #"{"type":"tool_calls","tool_calls":[{"id":"1","name":"echo","arguments":{}}]}"#,
            #"{"type":"tool_calls","tool_calls":[{"id":"1","name":"echo","arguments":{"value":1}}]}"#,
            #"{"type":"tool_calls","tool_calls":[{"id":"1","name":"echo","arguments":{"value":"ok","extra":true}}]}"#,
            #"{"type":"tool_calls","tool_calls":[{"id":"1","name":"echo","arguments":{"value":"a"}},{"id":"1","name":"echo","arguments":{"value":"b"}}]}"#,
            #"{"type":"final","content":"Answer","tool_calls":[]}"#,
            #"{"type":"final","content":""}"#,
            #"{"type":"tool_calls","tool_calls":[]}"#,
            #"{"type":"tool_calls","tool_calls":["#,
            "Answer",
        ]

        for output in invalid {
            XCTAssertThrowsError(
                try codec.decode(output: output, availableTools: [Self.echoTool]),
                "Expected rejection for \(output)"
            ) { error in
                XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidToolCallingResponse)
            }
        }
    }

    func testDynamicConstraintContainsOnlyCurrentTools() throws {
        let codec = BoneLlamaConstrainedJSONToolEnvelopeCodec()

        guard case let .jsonSchema(schema)? = try codec.generationConstraint(tools: [Self.echoTool]) else {
            return XCTFail("Expected JSON Schema constraint")
        }
        let encoded = String(decoding: try JSONEncoder().encode(schema), as: UTF8.self)

        XCTAssertTrue(encoded.contains("echo"))
        XCTAssertFalse(encoded.contains("lookup"))
        XCTAssertNoThrow(try BoneToolSchemaValidator.validateDefinition(schema))
    }

    func testEncodesV2AssistantHistoryWithoutTemplateTokens() throws {
        let codec = BoneLlamaConstrainedJSONToolEnvelopeCodec()
        let turn = try BoneInferenceAssistantTurn(content: [
            .toolCall(.init(
                id: "call-1",
                toolID: "test.echo",
                arguments: Data(#"{"value":"hello"}"#.utf8)
            )),
        ])

        let encoded = try codec.encodeAssistantTurn(turn, tools: [Self.echoTool])

        XCTAssertEqual(
            encoded,
            #"{"tool_calls":[{"arguments":{"value":"hello"},"id":"call-1","name":"echo"}],"type":"tool_calls"}"#
        )
        XCTAssertFalse(encoded.contains("<|im_start|>"))
    }

    private static let echoTool = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo a value",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: ["value": .string(enumValues: [], minimumLength: 1, maximumLength: 100)],
            required: ["value"],
            additionalProperties: false
        )
    )
}
