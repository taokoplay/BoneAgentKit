public struct BoneLlamaChatMLConversationRenderer: BoneLlamaConversationRendering, Sendable {
    private static let reservedTokens = ["<|im_start|>", "<|im_end|>"]
    private static let templateDigest = "aebb4f400dfe61249f64793948acd6b1dfa0b1c47ccebfbf06641d166d1e4ad0"

    public init() {}

    public func render(
        conversation: BoneLlamaConversation,
        using runtime: any BoneLlamaRuntime
    ) async throws -> BoneLlamaRenderedPrompt {
        guard conversation.messages.allSatisfy({ message in
            !Self.reservedTokens.contains(where: message.content.contains)
        }) else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
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
                templateDigest: Self.templateDigest,
                rendererID: "bone.chatml",
                rendererVersion: "1",
                reasoningMode: .disabled,
                addGenerationPrompt: true
            )
        )
    }
}
