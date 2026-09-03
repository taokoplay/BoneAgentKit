import Foundation

public enum BoneLlamaReasoningMode: String, Codable, Equatable, Hashable, Sendable {
    case disabled
}

public struct BoneLlamaTemplateIdentity: Codable, Equatable, Hashable, Sendable {
    public enum Source: String, Codable, Equatable, Hashable, Sendable {
        case sdk
        case ggufMetadata
    }

    public let source: Source
    public let templateDigest: String
    public let rendererID: String
    public let rendererVersion: String
    public let reasoningMode: BoneLlamaReasoningMode
    public let addGenerationPrompt: Bool

    public init(
        source: Source,
        templateDigest: String,
        rendererID: String,
        rendererVersion: String,
        reasoningMode: BoneLlamaReasoningMode,
        addGenerationPrompt: Bool
    ) throws {
        guard templateDigest.range(
            of: "^[0-9a-fA-F]{64}$",
            options: .regularExpression
        ) != nil,
              !rendererID.isEmpty,
              !rendererVersion.isEmpty else {
            throw BoneLlamaAdapterError.invalidConfiguration
        }
        self.source = source
        self.templateDigest = templateDigest
        self.rendererID = rendererID
        self.rendererVersion = rendererVersion
        self.reasoningMode = reasoningMode
        self.addGenerationPrompt = addGenerationPrompt
    }
}

public struct BoneLlamaRenderedPrompt: Sendable {
    public let prompt: String
    public let templateIdentity: BoneLlamaTemplateIdentity
    public let generationControl: BoneLlamaGenerationControl

    public init(
        prompt: String,
        templateIdentity: BoneLlamaTemplateIdentity
    ) throws {
        try self.init(
            prompt: prompt,
            templateIdentity: templateIdentity,
            generationControl: BoneLlamaGenerationControl()
        )
    }

    public init(
        prompt: String,
        templateIdentity: BoneLlamaTemplateIdentity,
        generationControl: BoneLlamaGenerationControl
    ) throws {
        guard !prompt.isEmpty else { throw BoneLlamaAdapterError.unsupportedRequest }
        self.prompt = prompt
        self.templateIdentity = templateIdentity
        self.generationControl = generationControl
    }
}

public protocol BoneLlamaConversationRendering: Sendable {
    func render(
        conversation: BoneLlamaConversation,
        using runtime: any BoneLlamaRuntime
    ) async throws -> BoneLlamaRenderedPrompt
}
