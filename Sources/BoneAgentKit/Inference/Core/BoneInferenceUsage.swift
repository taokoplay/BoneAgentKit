import Foundation

/// Provider 无关的安全 Token 用量摘要。
public struct BoneInferenceUsage: Codable, Equatable, Sendable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedInputTokens: Int?
    public let reasoningTokens: Int?
    /// Cache-write tokens reported separately by the Provider, not cache reads.
    public let cacheCreationInputTokens: Int?

    public init(
        inputTokens: Int,
        outputTokens: Int,
        cachedInputTokens: Int?,
        reasoningTokens: Int?,
        cacheCreationInputTokens: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedInputTokens = cachedInputTokens
        self.reasoningTokens = reasoningTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
    }

    public func validated() throws -> Self {
        guard inputTokens >= 0,
              outputTokens >= 0,
              cachedInputTokens.map({ $0 >= 0 }) ?? true,
              reasoningTokens.map({ $0 >= 0 }) ?? true,
              cacheCreationInputTokens.map({ $0 >= 0 }) ?? true else {
            throw BoneInferenceError.invalidUsage
        }
        return self
    }
}
