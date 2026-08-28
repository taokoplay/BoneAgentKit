import Foundation

/// 完整结果 Streaming 的有界网络预算；流本身没有整体墙钟时限。
public struct BoneInferenceEventStreamOptions: Equatable, Sendable {
    public let firstEventTimeout: TimeInterval
    public let idleTimeout: TimeInterval
    public let maximumBytes: Int

    public init(
        firstEventTimeout: TimeInterval = 90,
        idleTimeout: TimeInterval = 90,
        maximumBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.firstEventTimeout = firstEventTimeout
        self.idleTimeout = idleTimeout
        self.maximumBytes = max(0, maximumBytes)
    }
}
