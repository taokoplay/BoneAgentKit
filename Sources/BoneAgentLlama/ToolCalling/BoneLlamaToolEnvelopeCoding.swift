import BoneAgentKit

public struct BoneLlamaToolEnvelopeIdentity: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let version: String

    public init(id: String, version: String) {
        self.id = id
        self.version = version
    }
}

/// Runtime 可编译为 Grammar 的 Llama 层约束；当前阶段仅建立类型边界。
public enum BoneLlamaGenerationConstraint: Equatable, Sendable {
    case jsonSchema(BoneToolSchema)
    case enumChoice([String])
}

/// Tool wire envelope，只处理模型可见内容和严格解码，不渲染模型会话模板。
public protocol BoneLlamaToolEnvelopeCoding: Sendable {
    var identity: BoneLlamaToolEnvelopeIdentity { get }

    func systemInstructions(tools: [BoneAgentToolDefinition]) throws -> String

    func encodeAssistantTurn(
        _ turn: BoneInferenceAssistantTurn,
        tools: [BoneAgentToolDefinition]
    ) throws -> String

    func encodeToolResults(
        _ results: BoneInferenceToolResultBatch,
        tools: [BoneAgentToolDefinition]
    ) throws -> String

    func generationConstraint(
        tools: [BoneAgentToolDefinition]
    ) throws -> BoneLlamaGenerationConstraint?

    func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse
}

public extension BoneLlamaToolEnvelopeCoding {
    func generationConstraint(
        tools: [BoneAgentToolDefinition]
    ) throws -> BoneLlamaGenerationConstraint? { nil }
}
