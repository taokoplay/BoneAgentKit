import Foundation

/// 服务端生成策略，与返回内容的 reasoningDisclosure 独立。
/// providerDefault 表示不发送字段，不保证服务端默认开启或关闭。
public enum BoneInferenceServerReasoning: String, Codable, Hashable, Sendable {
    case providerDefault
    case enabled
    case disabled
}

/// 不支持的服务端推理策略在发送前拒绝，不改参数或自动回退。
public struct BoneInferenceUnsupportedServerReasoning: Error, Equatable, Sendable {
    public let requested: BoneInferenceServerReasoning
    public init(requested: BoneInferenceServerReasoning) { self.requested = requested }
}
