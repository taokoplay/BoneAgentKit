import Foundation

/// 推理引擎可独立声明的能力。
public enum BoneInferenceCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case structuredOutput
    case toolCalling
    case streaming
    case imageGeneration
}

/// BoneInference 边界上的稳定错误。
public enum BoneInferenceError: Error, Equatable, Sendable {
    case unsupportedCapability(BoneInferenceCapability)
    case invalidGenerationOptions
    case invalidMessage
    case invalidImageCount
    case invalidImageSize
    case invalidImagePayload
    case invalidImageMediaType
    case imagePayloadTooLarge
    case tooManyImagePayloads
    case imageResponseTooLarge
    case invalidResponse
    case tooManyToolCalls
    case toolArgumentsTooLarge
    case invalidUsage
    case invalidProviderContinuation
    case providerContinuationTooLarge
    case invalidToolResult
    case toolResultTooLarge
}
