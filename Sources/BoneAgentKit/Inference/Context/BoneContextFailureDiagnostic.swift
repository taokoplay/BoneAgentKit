import Foundation

/// Safe context-management failure categories. Never includes prompts, summaries,
/// provider payloads, underlying error descriptions or credentials.
public enum BoneContextFailureDiagnostic: String, Equatable, Sendable {
    case invalidConfiguration, invalidHistory, inputExceedsBudget
    case continuationUnsupported, summaryUnavailable, tokenCountingFailed
    case noProgress, revisionOverflow, unknown

    static func classify(_ error: Error) -> Self {
        if let error = error as? BoneContextCompactionError {
            switch error {
            case .invalidConfiguration: return .invalidConfiguration
            case .invalidHistory: return .invalidHistory
            case .mandatoryMessagesExceedBudget: return .inputExceedsBudget
            case .continuationUnsupported: return .continuationUnsupported
            case .summaryUnavailable: return .summaryUnavailable
            case .tokenCountingFailed: return .tokenCountingFailed
            case .noProgress: return .noProgress
            case .revisionOverflow: return .revisionOverflow
            }
        }
        if error is BoneContextWindowError { return .inputExceedsBudget }
        if error is BoneContextWindowBudgetError || error is BoneContextManagementConfigurationError { return .invalidConfiguration }
        if error is BoneContextSummarizerError { return .summaryUnavailable }
        return .unknown
    }
}
