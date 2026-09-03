import BoneAgentKit

/// Legacy ChatML + strict JSON Tool Calling adapter.
///
/// New integrations should compose `BoneLlamaJSONToolEnvelopeCodec` with one conversation
/// renderer so the model template is applied exactly once.
public struct BoneLlamaJSONToolCallingCodec: BoneLlamaToolCalling, Sendable {
    private let envelope = BoneLlamaJSONToolEnvelopeCodec()

    public init() {}

    public func encode(request: BoneInferenceRequest) throws -> String {
        let conversation = try BoneLlamaConversationBuilder.build(
            request: request,
            toolEnvelope: envelope
        )
        var prompt = ""
        for message in conversation.messages {
            prompt += "<|im_start|>\(message.role.rawValue)\n"
            prompt += message.content
            prompt += "<|im_end|>\n"
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    public func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        try envelope.decode(output: output, availableTools: availableTools)
    }
}
