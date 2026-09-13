import Foundation

/// 完整结果 Streaming 的有界网络预算；可显式限制整体时长与 Host 单调截止时间。
public struct BoneInferenceEventStreamOptions: Equatable, Sendable {
    public let firstEventTimeout: TimeInterval
    public let idleTimeout: TimeInterval
    public let maximumBytes: Int
    public let totalTimeout: TimeInterval?
    /// 与 ProcessInfo.processInfo.systemUptime 同一时基。
    public let deadlineUptime: TimeInterval?

    public init(
        firstEventTimeout: TimeInterval = 90,
        idleTimeout: TimeInterval = 90,
        maximumBytes: Int = 8 * 1_024 * 1_024,
        totalTimeout: TimeInterval? = nil,
        deadlineUptime: TimeInterval? = nil
    ) {
        self.totalTimeout = totalTimeout
        self.deadlineUptime = deadlineUptime
        self.firstEventTimeout = firstEventTimeout
        self.idleTimeout = idleTimeout
        self.maximumBytes = max(0, maximumBytes)
    }
}

/// 流式整体期限到达；与首事件及空闲超时区分。
public struct BoneInferenceStreamDeadlineExceeded: Error, Equatable, Sendable {
    public init() {}
}
