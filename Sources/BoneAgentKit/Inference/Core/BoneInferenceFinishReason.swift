import Foundation

/// Provider 无关的模型轮次终止原因。
public enum BoneInferenceFinishReason: Codable, Equatable, Sendable {
    case stop
    case toolCalls
    case length
    case contentFilter
    case safety
    case refusal
    case other(providerCode: String?)
}

/// Provider 返回的稳定拒绝分类；不携带原始正文。
public enum BoneInferenceRefusal: String, Codable, Equatable, Sendable {
    case safety
    case policy
    case permission
    case unsupported
    case unknown
}
