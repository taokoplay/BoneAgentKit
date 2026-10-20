import Foundation

public extension BoneInferenceDiagnosticSink {
    /// 仅安全摘要的可选日志适配；不接收 FailureCapture，也不输出服务端原始字符串。
    /// 业务阶段应由 Host 在自己的日志上下文中关联，不要把用户内容放入字段。
    static func logging(to configuration: BoneAgentLoggerConfiguration) -> Self {
        .init { event in
            let level: BoneAgentLogLevel
            switch event.phase {
            case .transportAttempt: level = .debug
            case .httpResponseReceived:
                level = event.response.map { (200...299).contains($0.statusCode) ? .info : .warning } ?? .info
            case .resultValidated: level = .info
            case .transportFailed, .responseValidationFailed: level = .warning
            }
            configuration.write(level, "inference_diagnostic", context: safeContext(event))
        }
    }
}

private func safeContext(_ event: BoneInferenceDiagnosticEvent) -> BoneAgentLogContext {
    var values = ["phase": String(describing: event.phase), "invocationID": event.invocationID.uuidString]
    if let stage = event.failureStage { values["failureStage"] = stage.rawValue }
    if let response = event.response {
        values["statusCode"] = String(response.statusCode)
        values["bodyBytes"] = String(response.bodyBytes)
        values["bodyKind"] = response.bodyKind.rawValue
        values["errorCategory"] = response.errorCategory.rawValue
        values["wireProtocol"] = String(describing: response.wireProtocol)
        values["shape"] = String(describing: response.shape)
        values["stop"] = String(describing: response.stop)
        values["inputTokens"] = safeCount(response.inputTokens)
        values["outputTokens"] = safeCount(response.outputTokens)
        values["totalTokens"] = safeCount(response.totalTokens)
        values["reasoningTokens"] = safeCount(response.reasoningTokens)
        values["toolCount"] = safeCount(response.toolCount)
    }
    return .init(values)
}

private func safeCount(_ count: BoneDiagnosticCount) -> String {
    switch count {
    case .unknown: return "unknown"
    case .invalid: return "invalid"
    case .value(let value): return String(value)
    }
}
