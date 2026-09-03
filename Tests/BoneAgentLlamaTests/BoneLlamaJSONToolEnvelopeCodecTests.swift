import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaJSONToolEnvelopeCodecTests: XCTestCase {
    func testEncodesInstructionsAndHistoryWithoutTemplateTokens() throws {
        let codec = BoneLlamaJSONToolEnvelopeCodec()
        let arguments = Data(#"{"value":"hello"}"#.utf8)
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

        let values = [
            try codec.systemInstructions(tools: [Self.tool]),
            try codec.encodeAssistantTurn(turn, tools: [Self.tool]),
            try codec.encodeToolResults(try .init(results: [result]), tools: [Self.tool]),
        ]

        XCTAssertTrue(values[0].contains("\"name\":\"echo\""))
        XCTAssertTrue(values[1].contains("\"id\":\"call-1\""))
        XCTAssertTrue(values[2].contains("\"content\":\"hello\""))
        for value in values {
            XCTAssertFalse(value.contains("<|im_start|>"))
            XCTAssertFalse(value.contains("<|im_end|>"))
        }
    }

    func testBuildsToolConversationAndValidatesResultCorrelation() throws {
        let codec = BoneLlamaJSONToolEnvelopeCodec()
        let arguments = Data(#"{"value":"hello"}"#.utf8)
        let turn = try BoneInferenceAssistantTurn(content: [
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

        let conversation = try BoneLlamaConversationBuilder.build(request: request, toolEnvelope: codec)

        XCTAssertEqual(conversation.messages.map(\.role), [.system, .user, .assistant, .tool])
        XCTAssertFalse(conversation.messages.contains { $0.content.contains("<|im_start|>") })
    }

    func testDecodesStrictCallsAndPlainText() throws {
        let codec = BoneLlamaJSONToolEnvelopeCodec()
        let response = try codec.decode(
            output: #"{"tool_calls":[{"id":"call-1","name":"echo","arguments":{"value":"hello"}}]}"#,
            availableTools: [Self.tool]
        )
        guard case let .assistantTurn(turn, reason, _, _, _) = response else {
            return XCTFail("Expected tool turn")
        }
        XCTAssertEqual(reason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.first?.toolID, "test.echo")
        XCTAssertEqual(
            try codec.decode(output: " Answer ", availableTools: [Self.tool]),
            .finish(.init(text: "Answer"))
        )
    }

    func testRejectsInvalidToolResponsesAndMismatchedHistory() throws {
        let codec = BoneLlamaJSONToolEnvelopeCodec()
        let invalidOutputs = [
            #"{"tool_calls":[{"id":"1","name":"missing","arguments":{}}]}"#,
            #"{"tool_calls":[{"id":"1","name":"echo","arguments":{}}]}"#,
            #"{"tool_calls":[{"id":"1","name":"echo","arguments":[]}] }"#,
            #"{"tool_calls":[]}"#,
            #"prefix {"tool_calls":[]}"#,
        ]
        for output in invalidOutputs {
            XCTAssertThrowsError(try codec.decode(output: output, availableTools: [Self.tool]))
        }

        let orphan = try BoneInferenceToolResult(
            callID: "orphan",
            toolID: "test.echo",
            content: .text("hello"),
            isError: false,
            ordinal: 0
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [
                .init(role: .user, content: "Echo"),
                .toolResults(try .init(results: [orphan])),
            ],
            availableTools: [Self.tool]
        )
        XCTAssertThrowsError(try BoneLlamaConversationBuilder.build(request: request, toolEnvelope: codec))
    }

    private static let tool = BoneAgentToolDefinition(
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
