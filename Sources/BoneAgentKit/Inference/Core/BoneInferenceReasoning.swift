import Foundation

/// 业务允许 Provider Adapter 交付的可读推理级别；不控制模型是否执行内部推理。
public enum BoneInferenceReasoningDisclosure: String, Codable, CaseIterable, Equatable, Sendable {
    case hidden
    case summary
    case providerReadable
}

/// 仅驻留内存的可读推理内容；故意不实现 Codable，避免进入普通检查点或持久化。
public struct BoneInferenceReasoning: Equatable, Sendable {
    public static let maximumUTF8ByteCount = 256 * 1_024

    public enum Kind: String, Equatable, Sendable {
        case summary
        case providerReadable
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) throws {
        guard !text.isEmpty,
              text.lengthOfBytes(using: .utf8) <= Self.maximumUTF8ByteCount else {
            throw BoneInferenceError.invalidReasoning
        }
        self.kind = kind
        self.text = text
    }
}

/// 正式推理响应与可选可读推理的内存信封；不自动记录或持久化。
public struct BoneInferenceDetailedResult: Equatable, Sendable {
    public let response: BoneInferenceResponse
    public let reasoning: BoneInferenceReasoning?

    public init(response: BoneInferenceResponse, reasoning: BoneInferenceReasoning?) {
        self.response = response
        self.reasoning = reasoning
    }
}
