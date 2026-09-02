import BoneAgentKit

/// A model-template adapter that adds Tool Calling semantics to a text-based Llama runtime.
///
/// Implementations own both sides of the protocol: request prompt encoding and generated-text
/// decoding. An engine declares `.toolCalling` only when an adapter is explicitly installed.
public protocol BoneLlamaToolCalling: Sendable {
    func encode(request: BoneInferenceRequest) throws -> String

    func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse
}
