import Foundation

/// Agent Runtime 对调用方公开的稳定错误，不包含 Tool ID 或敏感正文。
public enum BoneAgentError: Error, Codable, Equatable, Sendable {
    case invalidMaximumSteps
    case stepLimitReached
    case runAlreadyInProgress
    case unsupportedCapability(BoneInferenceCapability)
    case toolNotFound
    case toolPayloadTooLarge
    case inferenceFailed
    /// Tool 参数是合法 JSON，但不满足已声明 Schema；不携带参数值或未知键。
    case toolArgumentsInvalid
    /// 副作用可能已经发生但结果未知；Host 必须按原 Effect identity 恢复/对账。
    case toolOutcomeUnknown
    /// Tool 已返回，但 Receipt 持久化/提交未确认；不得直接重试 Tool。
    case toolRecoveryRequired
    case toolExecutionFailed
    case budgetExceeded
}
