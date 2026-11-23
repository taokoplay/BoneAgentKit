import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class BonePromptProfileTests: XCTestCase {
    func testProfileCompilesSectionsInStableOrder() throws {
        let profile = BonePromptProfile(
            id: "personal-assistant",
            version: 2,
            sections: [
                .init(id: "style", content: "回答简洁。", order: 2),
                .init(id: "identity", content: "你是个人助手。", order: 1)
            ]
        )

        let messages = try profile.systemMessages()

        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].role, .system)
        XCTAssertEqual(messages[0].content, "## identity\n你是个人助手。\n\n## style\n回答简洁。\n")
    }

    func testProfileRejectsDuplicateIDsAndOversizedContent() throws {
        let duplicate = BonePromptProfile(
            id: "developer",
            sections: [
                .init(id: "rules", content: "先分析。"),
                .init(id: "rules", content: "再验证。")
            ]
        )
        XCTAssertThrowsError(try duplicate.systemMessages()) { error in
            XCTAssertEqual(error as? BonePromptProfileError, .duplicateSectionID("rules"))
        }

        let oversized = BonePromptProfile(
            id: "developer",
            sections: [.init(id: "rules", content: String(repeating: "x", count: BonePromptProfile.maximumSectionContentBytes + 1))]
        )
        XCTAssertThrowsError(try oversized.systemMessages()) { error in
            XCTAssertEqual(error as? BonePromptProfileError, .sectionContentTooLarge)
        }
    }

    func testRunInjectsProfileBeforeExistingSystemAndUserMessages() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
        let agent = try makeAgent(engine)
        let profile = BonePromptProfile(
            id: "developer",
            sections: [.init(id: "identity", content: "你是开发助手。")]
        )

        _ = try await agent.run(
            modelID: "model",
            messages: [
                .init(role: .system, content: "宿主约束。"),
                .init(role: .user, content: "检查代码。")
            ],
            promptProfile: profile
        )

        let requests = await engine.receivedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.messages.compactMap(\.content), [
            "## identity\n你是开发助手。\n\n宿主约束。",
            "检查代码。"
        ])
    }


    func testComposeRejectsProfileAndHostSystemOverCombinedBudget() throws {
        let content = String(repeating: "x", count: 16_377)
        let profile = BonePromptProfile(
            id: "developer",
            sections: [
                .init(id: "a", content: content),
                .init(id: "b", content: content),
                .init(id: "c", content: content),
                .init(id: "d", content: content)
            ]
        )

        XCTAssertThrowsError(try profile.compose(messages: [
            .init(role: .system, content: "host")
        ])) { error in
            XCTAssertEqual(error as? BonePromptProfileError, .profileContentTooLarge)
        }
    }

    func testConversationStoresCompiledProfileMessagesForRestore() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "done")])
        let agent = try makeAgent(engine)
        let profile = BonePromptProfile(
            id: "personal-assistant",
            version: 3,
            sections: [.init(id: "identity", content: "你是个人助手。")]
        )

        let conversation = try await agent.makeConversation(
            modelID: "model",
            bindingID: "site",
            systemMessages: [.init(role: .system, content: "宿主约束。")],
            promptProfile: profile
        )

        let privateState = try await conversation.exportPrivateState()
        let state = try BoneAgentConversationState.decode(privateState)
        XCTAssertEqual(state.messages.compactMap(\.content), [
            "## identity\n你是个人助手。\n\n宿主约束。"
        ])
    }

    private func makeAgent(_ engine: any BoneInferenceEngine) throws -> BoneAgent {
        BoneAgent(
            inferenceEngine: engine,
            toolRegistry: try .init(tools: []),
            toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 2)
        )
    }
}
