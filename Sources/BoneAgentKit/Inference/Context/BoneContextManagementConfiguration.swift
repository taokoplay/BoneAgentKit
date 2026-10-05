import Foundation

public struct BoneContextManagementConfiguration: Sendable {
    /// nil 使用 Engine 的可选能力；显式 closure 返回 nil 表示该请求不管理。
    public let budgetProvider: (@Sendable (BoneInferenceRequest) -> BoneContextWindowBudget?)?
    public let summarizer: (any BoneContextSummarizing)?
    public let triggerFraction: Double
    public let targetFraction: Double
    public let preferredOutputTokens: Int?
    public let protocolReserveTokens: Int
    public let safetyMarginTokens: Int?
    /// Opt-in removal of completed exchanges in the current user Turn. Nil protects
    /// the entire current Turn; a positive value preserves that many recent exchanges.
    public let minimumRecentToolExchangeCount: Int?
    public let minimumRecentTurnCount: Int
    public let toolResultPolicy: @Sendable (String) -> BoneContextToolResultPolicy
    public let maximumSummaryOutputTokens: Int
    public let maximumSummaryCallsPerRun: Int
    public let fallbackToTrimming: Bool
    /// 仅接收安全元数据，不是持久化回执。
    public let summaryAttemptSink: @Sendable (BoneContextSummaryAttempt) async -> Void
    public let failureSink: @Sendable (BoneContextFailureDiagnostic) async -> Void
    public let receiptSink: @Sendable (BoneContextCompactionReceipt) async -> Void

    public init(
        budgetProvider: (@Sendable (BoneInferenceRequest) -> BoneContextWindowBudget?)? = nil,
        summarizer: (any BoneContextSummarizing)? = nil,
        triggerFraction: Double = 0.85, targetFraction: Double = 0.65,
        preferredOutputTokens: Int? = nil, protocolReserveTokens: Int = 128,
        safetyMarginTokens: Int? = nil, minimumRecentTurnCount: Int = 1,
        toolResultPolicy: @escaping @Sendable (String) -> BoneContextToolResultPolicy = { _ in .retain },
        maximumSummaryOutputTokens: Int = 1_024, maximumSummaryCallsPerRun: Int = 4,
        fallbackToTrimming: Bool = true,
        minimumRecentToolExchangeCount: Int? = nil,
        failureSink: @escaping @Sendable (BoneContextFailureDiagnostic) async -> Void = { _ in },
        summaryAttemptSink: @escaping @Sendable (BoneContextSummaryAttempt) async -> Void = { _ in },
        receiptSink: @escaping @Sendable (BoneContextCompactionReceipt) async -> Void = { _ in }
    ) throws {
        guard triggerFraction.isFinite, targetFraction.isFinite, targetFraction > 0,
              targetFraction < triggerFraction, triggerFraction <= 1,
              protocolReserveTokens >= 0, minimumRecentTurnCount > 0,
              minimumRecentToolExchangeCount.map({ $0 > 0 }) != false,
              maximumSummaryOutputTokens > 0, maximumSummaryCallsPerRun >= 0,
              preferredOutputTokens.map({ $0 > 0 }) != false,
              safetyMarginTokens.map({ $0 >= 0 }) != false else {
            throw BoneContextManagementConfigurationError.invalidConfiguration
        }
        self.budgetProvider = budgetProvider; self.summarizer = summarizer
        self.triggerFraction = triggerFraction; self.targetFraction = targetFraction
        self.preferredOutputTokens = preferredOutputTokens; self.protocolReserveTokens = protocolReserveTokens
        self.safetyMarginTokens = safetyMarginTokens; self.minimumRecentTurnCount = minimumRecentTurnCount
        self.toolResultPolicy = toolResultPolicy; self.maximumSummaryOutputTokens = maximumSummaryOutputTokens
        self.maximumSummaryCallsPerRun = maximumSummaryCallsPerRun; self.fallbackToTrimming = fallbackToTrimming
        self.minimumRecentToolExchangeCount = minimumRecentToolExchangeCount
        self.failureSink = failureSink
        self.receiptSink = receiptSink
        self.summaryAttemptSink = summaryAttemptSink
    }

    public static let disabled = try! Self(budgetProvider: { _ in nil })
}

public enum BoneContextManagementConfigurationError: Error, Equatable, Sendable { case invalidConfiguration }
