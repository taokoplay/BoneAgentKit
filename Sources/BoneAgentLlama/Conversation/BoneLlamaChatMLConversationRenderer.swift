public struct BoneLlamaChatMLConversationRenderer: BoneLlamaConversationRendering, Sendable {
    public init() {}

    public func render(
        conversation: BoneLlamaConversation,
        using runtime: any BoneLlamaRuntime
    ) async throws -> BoneLlamaRenderedPrompt {
        var prompt = ""
        for message in conversation.messages {
            prompt += "<|im_start|>\(message.role.rawValue)\n"
            prompt += message.content
            prompt += "<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return try .init(
            prompt: prompt,
            templateIdentity: .init(
                source: .sdk,
                templateDigest: "bone-chatml-v1",
                rendererID: "bone.chatml",
                rendererVersion: "1",
                reasoningMode: .disabled,
                addGenerationPrompt: true
            )
        )
    }
}
