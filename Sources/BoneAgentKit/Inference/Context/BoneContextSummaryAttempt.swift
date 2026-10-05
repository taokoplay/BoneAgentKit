import Foundation

/// 摘要调用与业务 RunModelSnapshot 分开计量；不携带正文、路径或原始错误。
public struct BoneContextSummaryAttempt: Equatable, Sendable {
    public enum Outcome: String, Sendable { case completed, rejected, failed, cancelled }
    public let modelID: String
    public let outcome: Outcome
    public let usage: BoneInferenceUsage?
    public let responseDelivered: Bool
}
