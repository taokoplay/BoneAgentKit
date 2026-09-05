import Foundation

/// 单次推理请求根据强类型字段自动推导出的能力需求；不包含消息或 Tool 内容。
public struct BoneInferenceRequirements: Equatable, Sendable {
    public let requiredCapabilities: Set<BoneInferenceCapability>
    public let structuredOutputFallback: BoneInferenceStructuredOutputFallbackPolicy?

    public init(request: BoneInferenceRequest) throws {
        let format = try request.responseFormat.validated()
        var required: Set<BoneInferenceCapability> = [.text]
        if !request.availableTools.isEmpty {
            required.insert(.toolCalling)
        }
        if let outputConstraint = request.outputConstraint {
            guard !format.isStructured, request.availableTools.isEmpty else {
                throw BoneInferenceError.invalidOutputConstraint
            }
            _ = try outputConstraint.validated()
            required.insert(.constrainedOutput)
        }
        requiredCapabilities = required
        structuredOutputFallback = format.fallbackPolicy
    }
}

/// 推理入口的调用方式；Streaming 会在请求本身需求之外增加流式能力。
public enum BoneInferenceInvocationMode: String, Codable, Equatable, Hashable, Sendable {
    case nonStreaming
    case streaming
}

/// 供应商无关的联网前 Capability 门禁。
public enum BoneInferenceCapabilityValidator {
    public static func validate(
        request: BoneInferenceRequest,
        capabilities: Set<BoneInferenceCapability>,
        invocation: BoneInferenceInvocationMode
    ) throws {
        let requirements = try BoneInferenceRequirements(request: request)
        for capability in requirements.requiredCapabilities.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard capabilities.contains(capability) else {
                throw BoneInferenceError.unsupportedCapability(capability)
            }
        }
        if invocation == .streaming, !capabilities.contains(.streaming) {
            throw BoneInferenceError.unsupportedCapability(.streaming)
        }
        if request.responseFormat.isStructured {
            try validateStructuredOutput(
                fallback: requirements.structuredOutputFallback,
                capabilities: capabilities
            )
        }
    }

    private static func validateStructuredOutput(
        fallback: BoneInferenceStructuredOutputFallbackPolicy?,
        capabilities: Set<BoneInferenceCapability>
    ) throws {
        if capabilities.contains(.structuredOutput) { return }
        if fallback == .nativeOrToolCall, capabilities.contains(.toolCalling) { return }
        throw BoneInferenceError.unsupportedStructuredOutput
    }
}
