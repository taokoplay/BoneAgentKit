import Foundation

/// 已知模型单次请求的不可变 Token 预算结果。
public struct BoneContextWindowPlan: Equatable, Sendable {
    public let messages: [BoneInferenceMessage]
    public let maximumOutputTokens: Int
    public let estimatedInputTokens: Int
    public let availableInputTokens: Int
    public let removedHistoryMessageCount: Int
}

/// Token 预算失败；只包含估算与限制，不包含任何消息正文。
public enum BoneContextWindowError: Error, Equatable, Sendable {
    case inputBudgetUnavailable(contextWindow: Int, requestedOutput: Int)
    case inputTokensExceeded(estimated: Int, limit: Int)
}

/// 基于完整 `BoneInferenceMessage` 的供应商无关请求预算规划器。
public enum BoneContextWindowPlanner {
    public static let defaultOutputTokens = 4_096
    public static let defaultProtocolReserveTokens = 512
    public static let minimumSafetyMarginTokens = 1_024

    /// 夹紧输出、校验不可裁剪消息，并从最旧历史开始裁剪。
    public static func plan(
        mandatoryMessages: [BoneInferenceMessage],
        history: [BoneInferenceMessage],
        modelLimits: BoneModelContextLimits,
        configuredOutputTokens: Int?,
        preferredOutputTokens: Int?,
        protocolReserveTokens: Int = defaultProtocolReserveTokens,
        safetyMarginTokens: Int? = nil
    ) throws -> BoneContextWindowPlan {
        let configured = configuredOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        let preferred = preferredOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        let desiredOutput: Int
        switch (configured, preferred) {
        case let (.some(configured), .some(preferred)):
            desiredOutput = min(configured, preferred)
        case let (.some(configured), .none):
            desiredOutput = configured
        case let (.none, .some(preferred)):
            desiredOutput = preferred
        case (.none, .none):
            desiredOutput = defaultOutputTokens
        }
        let maximumOutputTokens = modelLimits.maximumOutputTokens.map {
            min(desiredOutput, $0)
        } ?? desiredOutput
        let margin = safetyMarginTokens ?? max(
            minimumSafetyMarginTokens,
            modelLimits.contextWindowTokens / 100
        )
        let contextAvailable = modelLimits.contextWindowTokens
            - maximumOutputTokens
            - max(0, protocolReserveTokens)
            - max(0, margin)
        let availableInputTokens = min(
            modelLimits.maximumInputTokens ?? modelLimits.contextWindowTokens,
            contextAvailable
        )
        guard availableInputTokens > 0 else {
            throw BoneContextWindowError.inputBudgetUnavailable(
                contextWindow: modelLimits.contextWindowTokens,
                requestedOutput: maximumOutputTokens
            )
        }

        let mandatoryTokens = BoneTokenEstimator.estimateMessages(mandatoryMessages)
        guard mandatoryTokens <= availableInputTokens else {
            throw BoneContextWindowError.inputTokensExceeded(
                estimated: mandatoryTokens,
                limit: availableInputTokens
            )
        }

        let historyLimit = availableInputTokens - mandatoryTokens
        var keptReversed: [BoneInferenceMessage] = []
        var historyTokens = 0
        for message in history.reversed() {
            let messageTokens = BoneTokenEstimator.estimateMessage(message)
            guard historyTokens + messageTokens <= historyLimit else { break }
            keptReversed.append(message)
            historyTokens += messageTokens
        }
        let keptHistory = Array(keptReversed.reversed())
        let messages: [BoneInferenceMessage]
        if mandatoryMessages.count >= 2 {
            messages = [mandatoryMessages[0]]
                + keptHistory
                + Array(mandatoryMessages.dropFirst())
        } else {
            messages = keptHistory + mandatoryMessages
        }
        return BoneContextWindowPlan(
            messages: messages,
            maximumOutputTokens: maximumOutputTokens,
            estimatedInputTokens: mandatoryTokens + historyTokens,
            availableInputTokens: availableInputTokens,
            removedHistoryMessageCount: history.count - keptHistory.count
        )
    }
}
