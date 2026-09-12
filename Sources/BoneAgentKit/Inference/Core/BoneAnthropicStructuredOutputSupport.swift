import Foundation

/// Anthropic 兼容适配器的结构化输出支持。按实例配置、模型 profile 和调用方式计算。
/// Tool 输出支持只承诺严格验收，不保证模型一定调用 Tool；不包含隐式重试。
public struct BoneAnthropicStructuredOutputSupport: Equatable, Sendable {
    public let invocation: BoneInferenceInvocationMode
    public let toolCalling: Bool
    /// responseFormat 原生 JSON Schema 支持，不等同于 outputConstraint。
    public let nativeJSONSchema: Bool
    public let toolOutput: Bool
    public let forcedToolSelection: Bool
}
