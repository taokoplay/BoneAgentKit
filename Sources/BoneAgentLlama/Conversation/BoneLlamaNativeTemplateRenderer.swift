public struct BoneLlamaNativeTemplateRenderer: BoneLlamaConversationRendering, Sendable {
    public let reasoningMode: BoneLlamaReasoningMode
    public let addGenerationPrompt: Bool

    public init(
        reasoningMode: BoneLlamaReasoningMode = .disabled,
        addGenerationPrompt: Bool = true
    ) {
        self.reasoningMode = reasoningMode
        self.addGenerationPrompt = addGenerationPrompt
    }

    public func render(
        conversation: BoneLlamaConversation,
        using runtime: any BoneLlamaRuntime
    ) async throws -> BoneLlamaRenderedPrompt {
        guard let runtime = runtime as? any BoneLlamaNativeTemplateRenderingRuntime else {
            throw BoneLlamaRuntimeError.nativeTemplateUnavailable
        }
        return try await runtime.renderNativeTemplate(
            conversation: conversation,
            addGenerationPrompt: addGenerationPrompt,
            reasoningMode: reasoningMode
        )
    }
}
