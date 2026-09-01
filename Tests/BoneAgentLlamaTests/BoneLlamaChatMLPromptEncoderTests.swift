import BoneAgentKit
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaChatMLPromptEncoderTests: XCTestCase {
    func testEncodesTextConversationWithoutBusinessPrompt() throws {
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [
                .init(role: .system, content: "Be concise"),
                .init(role: .user, content: "Hello"),
                .init(role: .assistant, content: "Hi"),
            ]
        )

        let prompt = try BoneLlamaChatMLPromptEncoder().encode(request: request)

        XCTAssertEqual(prompt, """
        <|im_start|>system
        Be concise<|im_end|>
        <|im_start|>user
        Hello<|im_end|>
        <|im_start|>assistant
        Hi<|im_end|>
        <|im_start|>assistant

        """)
    }

    func testRejectsUnsupportedInferenceSemantics() throws {
        let tool = BoneAgentToolDefinition(
            id: "tool",
            version: "1",
            title: "Tool",
            summary: "Test"
        )
        let requests = [
            BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")], availableTools: [tool]),
            BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")], responseFormat: .jsonObject(fallback: .requireNative)),
            BoneInferenceRequest(modelID: "model", messages: [.init(role: .user, content: "Hi")], reasoningDisclosure: .summary),
        ]
        for request in requests {
            XCTAssertThrowsError(try BoneLlamaChatMLPromptEncoder().encode(request: request)) {
                XCTAssertEqual($0 as? BoneLlamaAdapterError, .unsupportedRequest)
            }
        }
    }
}
