import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaConversationBuilderTests: XCTestCase {
    func testBuildsOrderedTextConversationWithoutTemplateTokens() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [
                .init(role: .system, content: "Be concise."),
                .init(role: .user, content: "Hello"),
                .init(role: .assistant, content: "Hi"),
            ]
        )

        let conversation = try BoneLlamaConversationBuilder.build(request: request)

        XCTAssertEqual(conversation.messages, [
            try .init(role: .system, content: "Be concise."),
            try .init(role: .user, content: "Hello"),
            try .init(role: .assistant, content: "Hi"),
        ])
        XCTAssertFalse(conversation.messages.contains { $0.content.contains("<|im_start|>") })
        XCTAssertFalse(conversation.messages.contains { $0.content.contains("<|im_end|>") })
    }

    func testRejectsToolPayloadWithoutEnvelopeEncoder() throws {
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
        let requests = [
            BoneInferenceRequest(modelID: "model", messages: [.assistant(turn)]),
            BoneInferenceRequest(
                modelID: "model",
                messages: [.assistant(turn), .toolResults(try .init(results: [result]))]
            ),
        ]

        for request in requests {
            XCTAssertThrowsError(try BoneLlamaConversationBuilder.build(request: request)) { error in
                XCTAssertEqual(error as? BoneLlamaAdapterError, .unsupportedRequest)
            }
        }
    }

    func testRejectsUnsupportedRequestFields() {
        let requests = [
            BoneInferenceRequest(
                modelID: "model",
                messages: [.init(role: .user, content: "Hello")],
                availableTools: [Self.tool]
            ),
            BoneInferenceRequest(
                modelID: "model",
                messages: [.init(role: .user, content: "Hello")],
                responseFormat: .jsonObject(fallback: .requireNative)
            ),
            BoneInferenceRequest(
                modelID: "model",
                messages: [.init(role: .user, content: "Hello")],
                reasoningDisclosure: .summary
            ),
        ]

        for request in requests {
            XCTAssertThrowsError(try BoneLlamaConversationBuilder.build(request: request))
        }
    }

    func testConversationRejectsEmptyAndOversizedContent() {
        XCTAssertThrowsError(try BoneLlamaConversationMessage(role: .user, content: ""))
        XCTAssertThrowsError(try BoneLlamaConversationMessage(
            role: .user,
            content: String(repeating: "x", count: BoneLlamaConversationMessage.maximumContentByteCount + 1)
        ))
        XCTAssertThrowsError(try BoneLlamaConversation(messages: []))
    }

    private static let tool = BoneAgentToolDefinition(
        id: "test.echo",
        version: "1",
        title: "Echo",
        summary: "Echo",
        wireName: "echo",
        schemaVersion: 1,
        inputSchema: .object(
            properties: ["value": .string(enumValues: [], minimumLength: nil, maximumLength: nil)],
            required: ["value"],
            additionalProperties: false
        )
    )
}
