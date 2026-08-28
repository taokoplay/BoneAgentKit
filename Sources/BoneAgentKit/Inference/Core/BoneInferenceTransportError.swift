import Foundation

/// 不携带请求/响应正文、凭据或完整 URL 的稳定 Transport 错误。
public enum BoneInferenceTransportError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidConfiguration
    case invalidEndpoint
    case insecureEndpoint
    case reservedHeader
    case httpStatus(Int)
    case responseTooLarge
    case invalidResponse
    case rateLimited
    case quotaExceeded
    case unsupportedModel
    case safetyBlocked
    /// 模型输出命中 max_tokens 上限被截断；响应内容不完整，禁止当作完整正文交付。
    case outputTruncated
    case firstEventTimedOut
    case idleTimedOut
    case cancelled
    case network(BoneInferenceNetworkDiagnostic)
}
