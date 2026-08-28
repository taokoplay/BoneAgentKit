import Foundation

/// Agent Runtime 对调用方公开的稳定错误，不包含 Tool ID 或敏感正文。
public enum BoneAgentError: Error, Codable, Equatable, Sendable {
    case invalidMaximumSteps
    case stepLimitReached
    case runAlreadyInProgress
    case toolNotFound
    case toolPayloadTooLarge
    case inferenceFailed
    case toolExecutionFailed
    case budgetExceeded
}
