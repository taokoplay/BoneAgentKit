import Foundation

/// Agent Run 的安全终态；不得携带正文或原始响应。
public enum BoneAgentRunTerminalState: Codable, Equatable, Sendable {
    case succeeded
    case failed(BoneAgentError)
    case cancelled
}

/// 有序 observer 的最小四阶段事件；它不是持久状态事实源。
public enum BoneAgentEvent: Codable, Equatable, Sendable {
    case runStarted
    case toolCallStarted
    case toolCallFinished
    case runFinished(BoneAgentRunTerminalState)

    public var isTerminal: Bool {
        if case .runFinished = self { return true }
        return false
    }
}
