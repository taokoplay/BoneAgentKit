import BoneAgentKit

public protocol BoneLlamaPromptEncoding: Sendable {
    func encode(request: BoneInferenceRequest) throws -> String
}
