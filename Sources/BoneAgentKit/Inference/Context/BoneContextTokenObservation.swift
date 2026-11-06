import Foundation

/// Pure projections of budgets already used by the planner. Observation never loads images or a tokenizer.
enum BoneContextTokenObservation {
    static func managed(request: BoneInferenceRequest, count: Int?, before: Int?, stage: BoneAgentContextTokens.Stage,
                        budget: BoneContextWindowBudget, capacity: (maximumOutputTokens: Int, availableInputTokens: Int),
                        policy: BoneContextManagementConfiguration, imageMargin: Int, step: Int, revision: UInt64,
                        engine: any BoneInferenceEngine, summary: Bool = false, protocolReserve: Int? = nil) -> BoneAgentContextTokens {
        .init(modelID: request.modelID, step: step, stage: stage,
              source: count == nil ? .unavailable : (request.imageInputs.isEmpty && engine is any BoneInferenceContextTokenCounting ? .tokenizer : .estimate),
              inputTokens: count, inputTokensBeforeCompaction: before, imageCount: request.imageInputs.count,
              contextWindowTokens: budget.contextWindowTokens, availableInputTokens: capacity.availableInputTokens,
              reservedOutputTokens: capacity.maximumOutputTokens,
              protocolReserveTokens: protocolReserve ?? max(policy.protocolReserveTokens, request.imageInputs.isEmpty ? 0 : 128),
              safetyMarginTokens: max(imageMargin, policy.safetyMarginTokens ?? max(16, budget.contextWindowTokens / 50)),
              compactionTriggerTokens: summary ? nil : fraction(capacity.availableInputTokens, policy.triggerFraction),
              compactionTargetTokens: summary ? nil : fraction(capacity.availableInputTokens, policy.targetFraction), revision: revision)
    }

    static func unmanaged(request: BoneInferenceRequest, engine: any BoneInferenceEngine, step: Int) -> BoneAgentContextTokens {
        let estimator: BoneInferenceImageTokenEstimator?
        if let provider = engine as? any BoneInferenceImageTokenProviding {
            estimator = { try provider.imageTokens(for: $0, modelID: request.modelID) }
        } else { estimator = nil }
        let count = try? BoneTokenEstimator.estimateRequestTokens(request, imageTokenEstimator: estimator)
        return .init(modelID: request.modelID, step: step, stage: .unmanaged, source: count == nil ? .unavailable : .estimate,
                     inputTokens: count, inputTokensBeforeCompaction: nil, imageCount: request.imageInputs.count,
                     contextWindowTokens: nil, availableInputTokens: nil, reservedOutputTokens: nil,
                     protocolReserveTokens: nil, safetyMarginTokens: nil, compactionTriggerTokens: nil,
                     compactionTargetTokens: nil, revision: 0)
    }
    static func fraction(_ value: Int, _ fraction: Double) -> Int {
        guard fraction < 1 else { return value }
        let scaled = (Double(value) * fraction).rounded(.down)
        return scaled < Double(Int.max) ? min(value, Int(scaled)) : value
    }
}
