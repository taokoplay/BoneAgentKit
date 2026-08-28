import Foundation

/// 继续同一 Provider 模型轮次所需的有界 opaque 数据。
///
/// 该值不得进入日志、事件或安全报告；跨 Provider 使用会稳定失败。
public struct BoneInferenceProviderContinuation: Codable, Equatable, Sendable {
    public static let maximumByteCount = 256 * 1_024

    public let provider: BoneInferenceProviderKind
    public let data: Data

    public init(provider: BoneInferenceProviderKind, data: Data) throws {
        guard data.count <= Self.maximumByteCount else {
            throw BoneInferenceError.providerContinuationTooLarge
        }
        self.provider = provider
        self.data = data
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let provider = try container.decode(BoneInferenceProviderKind.self, forKey: .provider)
        let data = try container.decode(Data.self, forKey: .data)
        try self.init(provider: provider, data: data)
    }

    public func validate(for provider: BoneInferenceProviderKind) throws {
        guard self.provider == provider else {
            throw BoneInferenceError.invalidProviderContinuation
        }
    }

    private enum CodingKeys: CodingKey {
        case provider, data
    }
}
