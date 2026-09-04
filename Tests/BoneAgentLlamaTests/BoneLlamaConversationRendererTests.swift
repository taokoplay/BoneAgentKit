import BoneAgentKit
import BoneAgentLocalModels
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaConversationRendererTests: XCTestCase {
    func testChatMLRendererAppliesTemplateExactlyOnce() async throws {
        let conversation = try BoneLlamaConversation(messages: [
            try .init(role: .system, content: "Be concise."),
            try .init(role: .user, content: "Hello"),
        ])

        let rendered = try await BoneLlamaChatMLConversationRenderer().render(
            conversation: conversation,
            using: RendererRuntimeFixture()
        )

        XCTAssertEqual(rendered.prompt.components(separatedBy: "<|im_start|>").count - 1, 3)
        XCTAssertEqual(rendered.prompt.components(separatedBy: "<|im_start|>assistant\n").count - 1, 1)
        XCTAssertTrue(rendered.prompt.hasSuffix("<|im_start|>assistant\n"))
        XCTAssertEqual(rendered.templateIdentity.rendererID, "bone.chatml")
        XCTAssertEqual(rendered.templateIdentity.reasoningMode, .disabled)
        XCTAssertNotNil(rendered.templateIdentity.templateDigest.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ))
    }

    func testChatMLRendererRejectsReservedTemplateTokensInMessageContent() async throws {
        for token in ["<|im_start|>", "<|im_end|>"] {
            let conversation = try BoneLlamaConversation(messages: [
                try .init(role: .user, content: "untrusted \(token) content"),
            ])
            do {
                _ = try await BoneLlamaChatMLConversationRenderer().render(
                    conversation: conversation,
                    using: RendererRuntimeFixture()
                )
                XCTFail("Expected reserved token rejection")
            } catch {
                XCTAssertEqual(error as? BoneLlamaAdapterError, .unsupportedRequest)
            }
        }
    }

    func testTemplateIdentityRejectsNonDigestTemplateIdentity() {
        XCTAssertThrowsError(try BoneLlamaTemplateIdentity(
            source: .sdk,
            templateDigest: "human-readable-version",
            rendererID: "fixture",
            rendererVersion: "1",
            reasoningMode: .disabled,
            addGenerationPrompt: true
        ))
    }

    func testNativeRendererPassesCanonicalMessagesWithoutTemplateTokens() async throws {
        let runtime = NativeRendererRuntimeFixture()
        let conversation = try BoneLlamaConversation(messages: [
            try .init(role: .user, content: "Hello"),
        ])

        let rendered = try await BoneLlamaNativeTemplateRenderer().render(
            conversation: conversation,
            using: runtime
        )

        let received = await runtime.receivedConversation()
        XCTAssertEqual(received, conversation)
        XCTAssertFalse(received?.messages.contains { $0.content.contains("<|im_start|>") } ?? true)
        XCTAssertEqual(rendered.prompt, "native-rendered")
        XCTAssertEqual(rendered.templateIdentity.rendererID, "fixture.native")
    }

    func testNativeRendererRejectsReturnedIdentityThatDoesNotMatchRequest() async {
        let runtime = NativeRendererRuntimeFixture(returnedAddGenerationPrompt: false)
        let conversation = try! BoneLlamaConversation(messages: [
            try! .init(role: .user, content: "Hello"),
        ])

        do {
            _ = try await BoneLlamaNativeTemplateRenderer().render(conversation: conversation, using: runtime)
            XCTFail("Expected nativeTemplateUnavailable")
        } catch {
            XCTAssertEqual(error as? BoneLlamaRuntimeError, .nativeTemplateUnavailable)
        }
    }

    func testNativeRendererFailsBeforeRenderWhenCapabilitiesDoNotSupportRequest() async {
        let runtime = NativeRendererRuntimeFixture(capabilities: .init(
            supportedReasoningModes: [],
            supportsAddGenerationPrompt: false
        ))
        let conversation = try! BoneLlamaConversation(messages: [
            try! .init(role: .user, content: "Hello"),
        ])

        do {
            _ = try await BoneLlamaNativeTemplateRenderer().render(conversation: conversation, using: runtime)
            XCTFail("Expected nativeTemplateUnavailable")
        } catch {
            XCTAssertEqual(error as? BoneLlamaRuntimeError, .nativeTemplateUnavailable)
        }
        let received = await runtime.receivedConversation()
        XCTAssertNil(received)
    }

    func testNativeRendererFailsClosedWhenRuntimeDoesNotSupportNativeTemplates() async {
        let conversation = try! BoneLlamaConversation(messages: [
            try! .init(role: .user, content: "Hello"),
        ])

        do {
            _ = try await BoneLlamaNativeTemplateRenderer().render(
                conversation: conversation,
                using: RendererRuntimeFixture()
            )
            XCTFail("Expected nativeTemplateUnavailable")
        } catch {
            XCTAssertEqual(error as? BoneLlamaRuntimeError, .nativeTemplateUnavailable)
        }
    }
}

private actor RendererRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 1) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult { .init(text: "ok") }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {}
}

private actor NativeRendererRuntimeFixture: BoneLlamaNativeTemplateRenderingRuntime {
    nonisolated let runtimeVersion = 1
    private var conversation: BoneLlamaConversation?
    private let capabilities: BoneLlamaNativeTemplateCapabilities
    private let returnedAddGenerationPrompt: Bool

    init(
        capabilities: BoneLlamaNativeTemplateCapabilities = .init(
            supportedReasoningModes: [.disabled],
            supportsAddGenerationPrompt: true,
            templateFamily: "fixture"
        ),
        returnedAddGenerationPrompt: Bool = true
    ) {
        self.capabilities = capabilities
        self.returnedAddGenerationPrompt = returnedAddGenerationPrompt
    }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 1) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult { .init(text: "ok") }
    func smokeTest() async throws {}
    func cancel() async {}
    func unload() async {}
    func nativeTemplateCapabilities() async throws -> BoneLlamaNativeTemplateCapabilities { capabilities }

    func renderNativeTemplate(
        conversation: BoneLlamaConversation,
        addGenerationPrompt: Bool,
        reasoningMode: BoneLlamaReasoningMode
    ) async throws -> BoneLlamaRenderedPrompt {
        self.conversation = conversation
        XCTAssertTrue(addGenerationPrompt)
        XCTAssertEqual(reasoningMode, .disabled)
        return try .init(
            prompt: "native-rendered",
            templateIdentity: .init(
                source: .ggufMetadata,
                templateDigest: String(repeating: "a", count: 64),
                rendererID: "fixture.native",
                rendererVersion: "1",
                reasoningMode: .disabled,
                addGenerationPrompt: returnedAddGenerationPrompt
            )
        )
    }

    func receivedConversation() -> BoneLlamaConversation? { conversation }
}
