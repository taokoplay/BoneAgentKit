import Foundation

/// Provider 无关的安全 Token 用量摘要。
public struct BoneInferenceUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int?
    public let reasoningTokens: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int?,
        reasoningTokens: Int?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
    }

    public func validated() throws -> Self {
        guard inputTokens >= 0,
              outputTokens >= 0,
              cachedInputTokens.map({ $0 >= 0 }) ?? true,
              reasoningTokens.map({ $0 >= 0 }) ?? true else {
            throw BoneInferenceError.invalidUsage
        }
        return self
    }
}
