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
        let capabilities = try await runtime.nativeTemplateCapabilities()
        guard capabilities.supportedReasoningModes.contains(reasoningMode),
              !addGenerationPrompt || capabilities.supportsAddGenerationPrompt else {
            throw BoneLlamaRuntimeError.nativeTemplateUnavailable
        }
        let rendered = try await runtime.renderNativeTemplate(
            conversation: conversation,
            addGenerationPrompt: addGenerationPrompt,
            reasoningMode: reasoningMode
        )
        guard rendered.templateIdentity.source == .ggufMetadata,
              rendered.templateIdentity.reasoningMode == reasoningMode,
              rendered.templateIdentity.addGenerationPrompt == addGenerationPrompt else {
            throw BoneLlamaRuntimeError.nativeTemplateUnavailable
        }
        return rendered
    }
}
