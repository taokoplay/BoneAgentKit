import Foundation

/// 推理引擎可独立声明的能力。
public enum BoneInferenceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case structuredOutput
    case constrainedOutput
    case toolCalling
    case streaming
    case imageGeneration
}

/// BoneInference 边界上的稳定错误。
/// 针对具体 Engine 实例、模型、请求和调用方式解析出的不可变能力快照。
public struct BoneResolvedInferenceCapabilities: Equatable, Sendable {
    public let modelID: String
    public let invocation: BoneInferenceInvocationMode
    public let capabilities: Set<BoneInferenceCapability>

    public init(
        modelID: String,
        invocation: BoneInferenceInvocationMode,
        capabilities: Set<BoneInferenceCapability>
    ) {
        self.modelID = modelID
        self.invocation = invocation
        self.capabilities = capabilities
    }
}

public enum BoneInferenceError: Error, Equatable, Sendable {
    case unsupportedCapability(BoneInferenceCapability)
    case invalidGenerationOptions
    case invalidOutputConstraint
    case invalidStructuredOutputContract
    case unsupportedStructuredOutput
    case invalidMessage
    case invalidImageCount
    case invalidImageSize
    case invalidImagePayload
    case invalidImageMediaType
    case imagePayloadTooLarge
    case tooManyImagePayloads
    case imageResponseTooLarge
    case invalidResponse
    case invalidReasoning
    case tooManyToolCalls
    case toolArgumentsTooLarge
    case invalidUsage
    case invalidProviderContinuation
    case providerContinuationTooLarge
    case invalidToolResult
    case toolResultTooLarge
}
