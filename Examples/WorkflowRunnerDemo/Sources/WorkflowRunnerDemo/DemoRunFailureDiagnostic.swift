import Foundation
import BoneAgentKit

/// A bounded, value-free record suitable for local support diagnostics.
struct DemoRunFailureDiagnostic: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        case inferenceSteps, inferenceCalls, toolCalls, inputBytes, outputBytes, turns, duration, concurrency, cost
        case budget, toolPayload, outputTruncated, contextManagement, stateSize, inputSize
        case toolFailure, cancelled, authentication, rateLimited, quota, network, invalidResponse, configuration, unsupported, unknown
    }
    let formatVersion: Int
    let id: UUID
    let occurredAt: Date
    let code: Code
    let inferenceResponses: Int
    let toolPreparations: Int
    let completedTools: Int
    let networkConfirmations: Int
    let maximumReplyTokens: Int
    let tool: DemoToolFailure?

    init(error: any Error, failure: DemoLiveChatFailure, inferenceDiagnostic: BoneAgentInferenceFailureDiagnostic?,
         inferenceResponses: Int, toolPreparations: Int, completedTools: Int,
         networkConfirmations: Int, maximumReplyTokens: Int, tool: DemoToolFailure?) {
        formatVersion = 1; id = UUID(); occurredAt = Date()
        code = Self.classify(error, failure: failure, diagnostic: inferenceDiagnostic)
        self.inferenceResponses = inferenceResponses; self.toolPreparations = toolPreparations
        self.completedTools = completedTools; self.networkConfirmations = networkConfirmations
        self.maximumReplyTokens = maximumReplyTokens; self.tool = tool
    }

    var message: String {
        switch code {
        case .inferenceSteps: "模型已连续推理 \(DemoLiveChatSession.maximumInferenceSteps) 次仍未完成，本次任务已停止。请缩小问题范围或检查工具结果。"
        case .inferenceCalls, .turns: "已达到本轮模型调用上限，本次任务已停止。请缩小问题范围或检查工具是否被反复调用。"
        case .toolCalls: "已达到本轮 \(DemoLiveChatSession.maximumToolCalls) 次工具调用上限，本次任务已停止。"
        case .duration: "本次任务超过 \(Int(DemoLiveChatSession.maximumRunSeconds)) 秒。模型执行和等待确认均占用本轮时间，请检查后重新发起。"
        case .inputBytes: "本轮累计输入过大，请减少历史或材料后新建对话。"
        case .outputBytes: "本轮累计输出过大，请缩小任务范围后新建对话。"
        case .inputSize: "本次消息与材料预览过长，请缩短后重新发起。"
        case .toolPayload: "工具参数或结果超过大小限制，请减少材料范围。"
        case .outputTruncated: "模型输出被截断，本次回复未提交。本次回复上限为 \(maximumReplyTokens) Token，可在模型设置调整后重新发起。"
        case .contextManagement: "上下文整理未完成，请检查上下文设置或减少材料后新建对话。"
        case .stateSize: "对话状态超过保存范围，请减少材料后新建对话。"
        case .concurrency: "工具并发超过本轮允许范围，任务已停止。"
        case .cost: "已达到本轮配置的费用预算，任务已停止。"
        case .budget: "本轮执行预算检查未通过，任务已停止。可查看诊断中的调用计数。"
        case .configuration: "请求配置无效，请检查设置。"
        case .toolFailure: tool?.message ?? DemoLiveChatFailure.toolFailed.message
        case .cancelled: DemoLiveChatFailure.cancelled.message
        case .authentication: DemoLiveChatFailure.authentication.message
        case .rateLimited: DemoLiveChatFailure.rateLimited.message
        case .quota: DemoLiveChatFailure.quotaExceeded.message
        case .network: DemoLiveChatFailure.network.message
        case .invalidResponse: DemoLiveChatFailure.invalidResponse.message
        case .unsupported: DemoLiveChatFailure.unsupportedCapability.message
        case .unknown: DemoLiveChatFailure.unknown.message
        }
    }

    var text: String {
        var lines = ["Agent Lab 诊断 v\(formatVersion)", "记录：\(id.uuidString)",
            "时间：\(occurredAt.ISO8601Format())", "错误码：\(code.rawValue)",
            "完整模型响应数：\(inferenceResponses)", "工具准备次数：\(toolPreparations)",
            "已受理工具结果：\(completedTools)", "联网确认弹窗：\(networkConfirmations)",
            "单次回复上限：\(maximumReplyTokens) Token"]
        if let tool {
            lines.append("工具：\(tool.tool?.rawValue ?? "unknown")")
            lines.append("工具原因：\(tool.reason.rawValue)")
            lines.append("执行结果待核对：\(tool.requiresOutcomeReview)")
            if let issue = tool.resourceIssue { lines.append("资料读取原因：\(issue.rawValue)") }
        }
        return lines.joined(separator: "\n")
    }

    var isValid: Bool {
        formatVersion == 1 && occurredAt.timeIntervalSince1970.isFinite &&
        [inferenceResponses, toolPreparations, completedTools, networkConfirmations].allSatisfy { (0...1_000).contains($0) } &&
        (128...DemoModelCapacity.maximumConfigurableOutputTokens).contains(maximumReplyTokens)
    }

    private static func classify(_ error: any Error, failure: DemoLiveChatFailure,
                                 diagnostic: BoneAgentInferenceFailureDiagnostic?) -> Code {
        if failure == .cancelled { return .cancelled }
        if let budget = error as? BoneRunBudgetError {
            switch budget {
            case .inferenceCallLimitReached: return .inferenceCalls
            case .toolCallLimitReached: return .toolCalls
            case .inputByteLimitReached: return .inputBytes
            case .outputByteLimitReached: return .outputBytes
            case .turnLimitReached: return .turns
            case .wallClockLimitReached: return .duration
            case .concurrencyLimitReached: return .concurrency
            case .estimatedCostLimitReached: return .cost
            case .invalidBudget: return .configuration
            }
        }
        if let agent = error as? BoneAgentError {
            switch agent {
            case .stepLimitReached: return .inferenceSteps
            case .budgetExceeded: return .budget
            case .toolPayloadTooLarge: return .toolPayload
            case .contextManagementFailed: return .contextManagement
            default: break
            }
        }
        if error as? BoneInferenceTransportError == .outputTruncated || diagnostic == .outputTruncated { return .outputTruncated }
        if let conversation = error as? BoneAgentConversationError,
           conversation == .stateTooLarge || conversation == .revisionOverflow { return .stateSize }
        switch failure {
        case .configuration: return .configuration
        case .toolFailed: return .toolFailure
        case .limitReached: return .inputSize
        case .cancelled: return .cancelled
        case .authentication: return .authentication
        case .rateLimited: return .rateLimited
        case .quotaExceeded: return .quota
        case .network: return .network
        case .invalidResponse: return .invalidResponse
        case .unsupportedModel, .unsupportedCapability: return .unsupported
        case .unknown: return .unknown
        }
    }
}
