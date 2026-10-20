import Foundation
import CoreFoundation

/// 缺失和非法值均不等同于零。
public enum BoneDiagnosticCount: Equatable, Sendable {
    case unknown, invalid
    case value(Int)
}

/// 仅白名单元数据；不保留正文、Headers、供应商原始字符串或请求参数。
public struct BoneInferenceResponseDiagnostic: Equatable, Sendable {
    public enum WireProtocol: Sendable { case openAI, anthropic, gemini }
    public enum Shape: Sendable { case parsed, invalidJSON, tooLarge }
    public enum Stop: Sendable { case unknown, invalid, stop, toolCalls, length, blocked, other }
    public enum BodyKind: String, Sendable { case empty, json, html, text, unknown }
    public enum ErrorCategory: String, Sendable { case none, authentication, quota, rateLimit, safety, unknown }
    public let bodyKind: BodyKind
    public let errorCategory: ErrorCategory
    public let statusCode: Int
    public let bodyBytes: Int
    public let wireProtocol: WireProtocol
    public let shape: Shape
    public let stop: Stop
    public let toolCount: BoneDiagnosticCount
    public let inputTokens: BoneDiagnosticCount
    public let outputTokens: BoneDiagnosticCount
    public let totalTokens: BoneDiagnosticCount
    public let reasoningTokens: BoneDiagnosticCount

    static func capture(_ response: BoneInferenceHTTPResponse, wire: WireProtocol) -> Self {
        let data = response.data
        var bodyKind: BodyKind = data.isEmpty ? .empty : .unknown
        if !data.isEmpty, let header = response.headers.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value,
           header.utf8.count <= 256 {
            let mime = header.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            if mime == "application/json" || mime.hasSuffix("+json") { bodyKind = .json }
            else if mime == "text/html" || mime == "application/xhtml+xml" { bodyKind = .html }
            else if mime.hasPrefix("text/") { bodyKind = .text }
        }
        var errorCategory: ErrorCategory = (200...299).contains(response.statusCode) ? .none : .unknown
        switch response.statusCode {
        case 401: errorCategory = .authentication
        case 402: errorCategory = .quota
        case 429: errorCategory = .rateLimit
        default: break
        }
        var shape: Shape = .parsed
        var stop: Stop = .unknown
        var tools: BoneDiagnosticCount = .unknown
        var usage: [String: Any] = [:]
        var inputKey = "prompt_tokens", outputKey = "completion_tokens", totalKey = "total_tokens"
        var reasoning: Any?
        if data.count > 1_048_576 { shape = .tooLarge }
        else if let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // 成功解析的对象证据优先于服务端声明的 MIME；不按 HTML 文案猜测 WAF 根因。
            bodyKind = .json
            if !(200...299).contains(response.statusCode) {
                if BoneInferenceProviderResponseValidator.isSafetyBlocked(root) { errorCategory = .safety }
                else if let error = root["error"] as? [String: Any] {
                    let codes = [error["code"], error["type"], error["status"]].compactMap { $0 as? String }.filter { $0.utf8.count <= 64 }.map { $0.lowercased() }
                    if codes.contains(where: { ["insufficient_quota", "quota_exceeded"].contains($0) }) { errorCategory = .quota }
                    else if codes.contains(where: { ["rate_limit_exceeded", "rate_limit_error"].contains($0) }) { errorCategory = .rateLimit }
                    else if codes.contains(where: { ["invalid_api_key", "authentication_error", "unauthenticated"].contains($0) }) { errorCategory = .authentication }
                }
            }
            var rawStop: Any?
            switch wire {
            case .openAI:
                if let choices = root["choices"] as? [[String: Any]], choices.count == 1, let choice = choices.first {
                    rawStop = choice["finish_reason"]
                    if let message = choice["message"] as? [String: Any] { tools = countArray(message["tool_calls"]) }
                }
                usage = root["usage"] as? [String: Any] ?? [:]
                if let details = usage["completion_tokens_details"] {
                    reasoning = (details as? [String: Any]).map { $0["reasoning_tokens"] } ?? NSNull()
                }
            case .anthropic:
                rawStop = root["stop_reason"]
                tools = countBlocks(root["content"], key: "type", value: "tool_use")
                usage = root["usage"] as? [String: Any] ?? [:]
                inputKey = "input_tokens"; outputKey = "output_tokens"
            case .gemini:
                if let candidates = root["candidates"] as? [[String: Any]], candidates.count == 1, let candidate = candidates.first {
                    rawStop = candidate["finishReason"]
                    let parts = (candidate["content"] as? [String: Any])?["parts"]
                    tools = countBlocks(parts, key: "functionCall", value: nil)
                }
                usage = root["usageMetadata"] as? [String: Any] ?? [:]
                inputKey = "promptTokenCount"; outputKey = "candidatesTokenCount"; totalKey = "totalTokenCount"
                reasoning = usage["thoughtsTokenCount"]
            }
            if let rawStop {
                if let value = rawStop as? String, value.utf8.count <= 64 {
                    switch value {
                    case "stop", "end_turn", "STOP": stop = .stop
                    case "tool_calls", "tool_use": stop = .toolCalls
                    case "length", "max_tokens", "max_output_tokens", "MAX_TOKENS": stop = .length
                    case "content_filter", "safety", "SAFETY", "refusal": stop = .blocked
                    default: stop = .other
                    }
                } else { stop = .invalid }
            }
            // 非对象 usage 与缺失 usage 不混同。
            let usageKey = wire == .gemini ? "usageMetadata" : "usage"
            if let raw = root[usageKey], !(raw is [String: Any]) {
                usage = [inputKey: NSNull(), outputKey: NSNull(), totalKey: NSNull()]
                reasoning = NSNull()
            }
        } else { shape = .invalidJSON }
        return .init(bodyKind: bodyKind, errorCategory: errorCategory, statusCode: response.statusCode, bodyBytes: data.count, wireProtocol: wire,
                     shape: shape, stop: stop, toolCount: tools,
                     inputTokens: number(usage[inputKey]), outputTokens: number(usage[outputKey]),
                     totalTokens: number(usage[totalKey]), reasoningTokens: number(reasoning))
    }

    private static func number(_ raw: Any?) -> BoneDiagnosticCount {
        guard let raw else { return .unknown }
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 9_007_199_254_740_991,
              let value = Int(exactly: n.doubleValue) else { return .invalid }
        return .value(value)
    }
    private static func countArray(_ raw: Any?) -> BoneDiagnosticCount {
        guard let raw else { return .unknown }
        guard let array = raw as? [Any], array.count <= 128 else { return .invalid }
        return .value(array.count)
    }
    private static func countBlocks(_ raw: Any?, key: String, value: String?) -> BoneDiagnosticCount {
        guard let raw else { return .unknown }
        guard let blocks = raw as? [[String: Any]], blocks.count <= 128 else { return .invalid }
        var count = 0
        for block in blocks {
            if let value {
                guard let kind = block[key] as? String else { return .invalid }
                if kind == value { count += 1 }
            } else if let raw = block[key] {
                guard raw is [String: Any] else { return .invalid }
                count += 1
            }
        }
        return .value(count)
    }
}

public struct BoneInferenceDiagnosticEvent: Sendable {
    public enum Phase: Sendable { case transportAttempt, httpResponseReceived, resultValidated, transportFailed, responseValidationFailed }
    public enum FailureStage: String, Sendable { case transport, httpStatus, jsonDecoding, resultValidation }
    public let failureStage: FailureStage?
    /// 本地调用关联 ID，不是供应商请求 ID 或计费凭据。
    public let invocationID: UUID
    public let phase: Phase
    public let response: BoneInferenceResponseDiagnostic?
}

/// 同步、非抛错回调；Host 应快速返回并自行确保线程安全，不在回调内等待推理完成。
/// nil handler 时不构造摘要。不记录供应商 ID，不推断重试或计费。
public struct BoneInferenceDiagnosticSink: Sendable {
    private let handler: (@Sendable (BoneInferenceDiagnosticEvent) -> Void)?
    public init(_ handler: (@Sendable (BoneInferenceDiagnosticEvent) -> Void)? = nil) { self.handler = handler }
    var isEnabled: Bool { handler != nil }
    func emit(_ id: UUID, _ phase: BoneInferenceDiagnosticEvent.Phase, response: BoneInferenceHTTPResponse? = nil,
              wire: BoneInferenceResponseDiagnostic.WireProtocol, failureStage: BoneInferenceDiagnosticEvent.FailureStage? = nil) {
        guard let handler else { return }
        handler(.init(failureStage: failureStage, invocationID: id, phase: phase, response: response.map { .capture($0, wire: wire) }))
    }
}
