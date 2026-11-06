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

    public static func plan(
        mandatoryMessages: [BoneInferenceMessage],
        history: [BoneInferenceMessage],
        modelLimits: BoneModelContextLimits,
        configuredOutputTokens: Int?,
        preferredOutputTokens: Int?,
        protocolReserveTokens: Int = defaultProtocolReserveTokens,
        safetyMarginTokens: Int? = nil,
        imageTokenEstimator: BoneInferenceImageTokenEstimator? = nil
    ) throws -> BoneContextWindowPlan {
        try plan(
            mandatoryMessages: mandatoryMessages,
            history: history,
            budget: modelLimits.contextWindowBudget,
            configuredOutputTokens: configuredOutputTokens,
            preferredOutputTokens: preferredOutputTokens,
            protocolReserveTokens: protocolReserveTokens,
            safetyMarginTokens: safetyMarginTokens,
            imageTokenEstimator: imageTokenEstimator
        )
    }

    public static func plan(
        mandatoryMessages: [BoneInferenceMessage],
        history: [BoneInferenceMessage],
        budget: BoneContextWindowBudget,
        configuredOutputTokens: Int?,
        preferredOutputTokens: Int?,
        protocolReserveTokens: Int = defaultProtocolReserveTokens,
        safetyMarginTokens: Int? = nil,
        imageTokenEstimator: BoneInferenceImageTokenEstimator? = nil
    ) throws -> BoneContextWindowPlan {
        let capacity = try budget.availableInputTokens(
            configuredOutputTokens: configuredOutputTokens,
            preferredOutputTokens: preferredOutputTokens,
            protocolReserveTokens: protocolReserveTokens,
            safetyMarginTokens: safetyMarginTokens
        )
        let maximumOutputTokens = capacity.maximumOutputTokens
        let availableInputTokens = capacity.availableInputTokens
        let mandatoryTokens = try BoneTokenEstimator.estimateMessages(mandatoryMessages, imageTokenEstimator: imageTokenEstimator)
        guard mandatoryTokens <= availableInputTokens else {
            throw BoneContextWindowError.inputTokensExceeded(
                estimated: mandatoryTokens,
                limit: availableInputTokens
            )
        }

        let historyLimit = availableInputTokens - mandatoryTokens
        var keptReversed: [BoneInferenceMessage] = []
        var historyTokens = 0
        let hasImages = (mandatoryMessages + history).contains { !$0.imageInputs.isEmpty }
        let historyGroups: [[BoneInferenceMessage]]
        if hasImages {
            let segmented = try BoneContextTurn.split(history)
            guard segmented.head.isEmpty else { throw BoneContextCompactionError.invalidHistory }
            historyGroups = segmented.turns.map(\.messages)
        } else {
            historyGroups = history.map { [$0] }
        }
        for group in historyGroups.reversed() {
            let groupTokens = try BoneTokenEstimator.estimateMessages(group, imageTokenEstimator: imageTokenEstimator)
            guard groupTokens <= historyLimit - historyTokens else { break }
            keptReversed.append(contentsOf: group.reversed())
            historyTokens += groupTokens
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
        if hasImages { _ = try BoneContextTurn.split(messages) }
        return BoneContextWindowPlan(
            messages: messages,
            maximumOutputTokens: maximumOutputTokens,
            estimatedInputTokens: mandatoryTokens + historyTokens,
            availableInputTokens: availableInputTokens,
            removedHistoryMessageCount: history.count - keptHistory.count
        )
    }
}
