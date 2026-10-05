import Foundation

/// 单个 Run 的私有上下文状态，不 Codable，不写普通 Workflow checkpoint。
struct BoneContextSession {
    var revision: UInt64 = 0
    var summary: String?
    var summaryCalls = 0

    struct Prepared {
        let request: BoneInferenceRequest
        let history: [BoneInferenceMessage]
        let receipt: BoneContextCompactionReceipt?
        var managed: Bool = true
    }

    mutating func prepare(
        request: BoneInferenceRequest, engine: any BoneInferenceEngine,
        policy: BoneContextManagementConfiguration, meter: BoneRunBudgetMeter?,
        clock: @Sendable () -> TimeInterval
    ) async throws -> Prepared {
        try Task.checkCancellation()
        try await meter?.checkWallClock(nowUptime: clock())
        let configuredBudget = policy.budgetProvider?(request)
        if policy.budgetProvider != nil, configuredBudget == nil {
            guard summary == nil else { throw BoneContextCompactionError.invalidConfiguration }
            return .init(request: request, history: request.messages, receipt: nil, managed: false)
        }
        let engineBudget = try (engine as? any BoneInferenceContextBudgetProviding)?.contextBudget(for: request.modelID)
        guard let budget = configuredBudget ?? engineBudget else {
            guard summary == nil else { throw BoneContextCompactionError.invalidConfiguration }
            return .init(request: request, history: request.messages, receipt: nil, managed: false)
        }
        _ = try BoneContextTurn.split(request.messages)
        let effectiveBudget = try budget.constrained(by: engineBudget)
        let capacity = try Self.capacity(effectiveBudget, request: request, policy: policy)
        let effectiveMessages = try compose(request.messages, summary: summary)
        let normalizedContinuation: BoneInferenceProviderContinuation?
        if let continuation = request.providerContinuation, effectiveMessages != request.messages {
            guard let adapter = engine as? any BoneInferenceContextRebinding else {
                throw BoneContextCompactionError.continuationUnsupported
            }
            // Conversation state normally stores continuation against raw history.
            // A caller may already pass a continuation bound to the current
            // effective projection (for example an in-flight compacted Run), so
            // validate that form first; otherwise rebind raw -> effective.
            if let current = try? adapter.rebindContextContinuation(
                continuation, from: effectiveMessages, to: effectiveMessages
            ) {
                normalizedContinuation = current
            } else {
                normalizedContinuation = try adapter.rebindContextContinuation(
                    continuation, from: request.messages, to: effectiveMessages
                )
            }
        } else {
            normalizedContinuation = request.providerContinuation
        }
        let baseRequest = Self.replacing(
            request, messages: request.messages, output: capacity.maximumOutputTokens,
            continuation: normalizedContinuation, replaceContinuation: true
        )
        let original = Self.replacing(baseRequest, messages: effectiveMessages, output: capacity.maximumOutputTokens)
        let initialCount = try await Self.count(original, engine: engine)
        try Task.checkCancellation()
        try await meter?.checkWallClock(nowUptime: clock())
        let threshold = Self.fraction(capacity.availableInputTokens, policy.triggerFraction)
        guard initialCount >= threshold else { return .init(request: original, history: request.messages, receipt: nil) }
        let groups = try BoneContextTurn.split(request.messages)
        let clamped = try BoneContextCompactor.clampToolResults(in: request.messages, policy: policy.toolResultPolicy)
        let segments = try BoneContextTurn.split(clamped.messages)
        let protectedCount = min(policy.minimumRecentTurnCount, segments.turns.count)
        let maximumDrop = segments.turns.count - protectedCount
        var dropped = 0
        var history = clamped.messages
        var candidate = try rebound(baseRequest, history: history, summary: summary, engine: engine, output: capacity.maximumOutputTokens)
        let target = Self.fraction(capacity.availableInputTokens, policy.targetFraction)
        var count = try await Self.count(candidate, engine: engine)
        while count > target, dropped < maximumDrop {
            dropped += 1
            history = segments.head + segments.turns.dropFirst(dropped).flatMap(\.messages)
            candidate = try rebound(baseRequest, history: history, summary: summary, engine: engine, output: capacity.maximumOutputTokens)
            count = try await Self.count(candidate, engine: engine)
            try Task.checkCancellation()
            try await meter?.checkWallClock(nowUptime: clock())
        }
        var removed = segments.turns.prefix(dropped).flatMap(\.messages)
        var removedExchanges = 0
        if let keep = policy.minimumRecentToolExchangeCount {
            // Only the latest user Turn is eligible, and only adjacent, completed
            // assistant/tool pairs. Its user request and recent pairs are immutable.
            let currentStart = history.lastIndex(where: { $0.role == .user }) ?? history.count
            let pairs = history.indices.filter { index in
                index > currentStart && index + 1 < history.count &&
                !(history[index].assistantTurn?.toolCalls.isEmpty ?? true) && history[index + 1].role == .tool
            }
            var removedIndices = Set<Int>()
            for index in pairs.dropLast(min(keep, pairs.count)) where count > target {
                removedIndices.insert(index); removedIndices.insert(index + 1)
                removed += [history[index], history[index + 1]]
                removedExchanges += 1
                let trimmed = history.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
                candidate = try rebound(baseRequest, history: trimmed, summary: summary, engine: engine, output: capacity.maximumOutputTokens)
                count = try await Self.count(candidate, engine: engine)
                try Task.checkCancellation()
                try await meter?.checkWallClock(nowUptime: clock())
            }
            history = history.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
            _ = try BoneContextTurn.split(history)
        }
        guard count <= capacity.availableInputTokens else {
            throw BoneContextCompactionError.mandatoryMessagesExceedBudget(estimated: count, limit: capacity.availableInputTokens)
        }
        var nextSummary = summary
        var usedSummary = false
        var fallback = false
        if !removed.isEmpty, let summarizer = policy.summarizer {
            do {
                let value = try await summarize(removed, binding: summarizer, policy: policy, meter: meter, clock: clock)
                let summarized = try rebound(baseRequest, history: history, summary: value, engine: engine, output: capacity.maximumOutputTokens)
                let summarizedCount = try await Self.count(summarized, engine: engine)
                guard summarizedCount <= capacity.availableInputTokens, summarizedCount < initialCount else {
                    throw BoneContextSummarizerError.summaryTooLarge
                }
                candidate = summarized; count = summarizedCount; nextSummary = value; usedSummary = true
            } catch is CancellationError { throw CancellationError() }
            catch let error as BoneRunBudgetError { throw error }
            catch {
                try Task.checkCancellation()
                // 完整但无效的摘要、输入装不下或次数已用尽可以裁剪回退；
                // 网络/未知提交失败不能被吞掉后继续发请求。
                guard error is BoneContextSummarizerError else { throw BoneContextCompactionError.summaryUnavailable }
                guard policy.fallbackToTrimming else { throw BoneContextCompactionError.summaryUnavailable }
                fallback = true
            }
        }
        try Task.checkCancellation()
        try await meter?.checkWallClock(nowUptime: clock())
        // 所有校验完成后才提交 run-local 状态；无变化时不增长 revision。
        guard history != request.messages || usedSummary else { return .init(request: original, history: request.messages, receipt: nil) }
        guard count < initialCount else { throw BoneContextCompactionError.noProgress }
        guard revision < UInt64.max else { throw BoneContextCompactionError.revisionOverflow }
        let receipt = BoneContextCompactionReceipt(
            strategy: usedSummary ? .summary : (removedExchanges > 0 ? .tiered : (dropped > 0 ? .slidingWindow : .toolResultClamp)),
            sourceRevision: revision, resultingRevision: revision + 1,
            removedTurnCount: dropped, removedMessageCount: groups.turns.prefix(dropped).reduce(0) { $0 + $1.messages.count } + removedExchanges * 2,
            estimatedRequestTokenReduction: initialCount - count, clampedToolResultCount: clamped.clampedToolResultCount,
            usedModelSummary: usedSummary, fallbackUsed: fallback, removedToolExchangeCount: removedExchanges
        )
        revision += 1; summary = nextSummary
        return .init(request: candidate, history: history, receipt: receipt)
    }

    private mutating func summarize(_ removed: [BoneInferenceMessage], binding: any BoneContextSummarizing,
                                    policy: BoneContextManagementConfiguration, meter: BoneRunBudgetMeter?,
                                    clock: @Sendable () -> TimeInterval) async throws -> String {
        guard summaryCalls < policy.maximumSummaryCallsPerRun else { throw BoneContextSummarizerError.callLimitReached }
        let engineBudget = try (binding.engine as? any BoneInferenceContextBudgetProviding)?.contextBudget(for: binding.modelID)
        let effectiveBudget = try binding.budget.constrained(by: engineBudget)
        var output = min(policy.maximumSummaryOutputTokens, effectiveBudget.maximumOutputTokens ?? policy.maximumSummaryOutputTokens,
                         max(1, effectiveBudget.contextWindowTokens / 4))
        var request = try BoneContextSummaryCodec.request(modelID: binding.modelID, messages: removed, previous: summary, maximumOutputTokens: output)
        let capacity = try Self.capacity(effectiveBudget, request: request, policy: policy)
        output = capacity.maximumOutputTokens
        request = Self.replacing(request, messages: request.messages, output: output)
        let available = capacity.availableInputTokens
        guard try await Self.count(request, engine: binding.engine) <= available else { throw BoneContextSummarizerError.inputTooLarge }
        let resolved = try binding.engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
        try BoneInferenceCapabilityValidator.validate(request: request, capabilities: resolved.capabilities, invocation: resolved.invocation)
        try Task.checkCancellation()
        var cost: Int64 = 0
        if meter != nil {
            guard let estimate = binding.costEstimator else { throw BoneRunBudgetError.invalidBudget }
            cost = try estimate(request)
        }
        try await meter?.reserveInference(inputBytes: JSONEncoder().encode(request).count, estimatedCostMicrounits: cost, nowUptime: clock())
        summaryCalls += 1
        var delivered = false
        var usage: BoneInferenceUsage?
        do {
            let response = try await binding.engine.infer(request: request)
            delivered = true
            usage = response.usage
            try await meter?.commitInference(outputBytes: JSONEncoder().encode(response).count)
            try Task.checkCancellation()
            try await meter?.checkWallClock(nowUptime: clock())
            let text = try BoneContextSummaryCodec.decode(response, maximumTokens: output)
            await policy.summaryAttemptSink(.init(modelID: binding.modelID, outcome: .completed, usage: usage, responseDelivered: true))
            return text
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? BoneInferenceTransportError) == .cancelled
            await policy.summaryAttemptSink(.init(modelID: binding.modelID,
                outcome: cancelled ? .cancelled : (delivered ? .rejected : .failed), usage: usage, responseDelivered: delivered))
            if cancelled { throw CancellationError() }
            if (error as? BoneInferenceTransportError) == .outputTruncated { throw BoneContextSummarizerError.unsupportedResponse }
            throw error
        }
    }

    private func rebound(_ request: BoneInferenceRequest, history: [BoneInferenceMessage], summary: String?,
                         engine: any BoneInferenceEngine, output: Int) throws -> BoneInferenceRequest {
        let messages = try compose(history, summary: summary)
        var continuation = request.providerContinuation
        if let value = continuation, messages != (try compose(request.messages, summary: self.summary)) {
            guard let adapter = engine as? any BoneInferenceContextRebinding else { throw BoneContextCompactionError.continuationUnsupported }
            continuation = try adapter.rebindContextContinuation(value, from: compose(request.messages, summary: self.summary), to: messages)
        }
        return Self.replacing(request, messages: messages, output: output, continuation: continuation, replaceContinuation: true)
    }

    private func compose(_ messages: [BoneInferenceMessage], summary: String?) throws -> [BoneInferenceMessage] {
        guard let summary else { return messages }
        let head = messages.prefix { $0.role == .system }
        return Array(head) + [try BoneContextSummaryCodec.message(summary)] + messages.dropFirst(head.count)
    }

    static func capacity(_ budget: BoneContextWindowBudget, request: BoneInferenceRequest,
                         policy: BoneContextManagementConfiguration) throws -> (maximumOutputTokens: Int, availableInputTokens: Int) {
        let preferred = policy.preferredOutputTokens ?? min(4_096, max(1, budget.contextWindowTokens / 4))
        return try budget.availableInputTokens(configuredOutputTokens: request.generationOptions.maximumOutputTokens,
                                              preferredOutputTokens: preferred,
                                              protocolReserveTokens: policy.protocolReserveTokens,
                                              safetyMarginTokens: policy.safetyMarginTokens ?? max(16, budget.contextWindowTokens / 50))
    }

    static func count(_ request: BoneInferenceRequest, engine: any BoneInferenceEngine) async throws -> Int {
        if let counter = engine as? any BoneInferenceContextTokenCounting {
            do {
                let count = try await counter.countContextTokens(request: request)
                guard count >= 0 else { throw BoneContextCompactionError.tokenCountingFailed }
                return count
            } catch is CancellationError { throw CancellationError() }
            catch let error as BoneRunBudgetError { throw error }
            catch {
                if Task.isCancelled || (error as? BoneInferenceTransportError) == .cancelled { throw CancellationError() }
                throw BoneContextCompactionError.tokenCountingFailed
            }
        }
        return BoneTokenEstimator.estimateMessages(request.messages) + (try BoneTokenEstimator.estimateRequestOverhead(request))
    }

    private static func fraction(_ value: Int, _ fraction: Double) -> Int {
        guard fraction < 1 else { return value }
        let scaled = (Double(value) * fraction).rounded(.down)
        guard scaled < Double(Int.max) else { return value }
        return min(value, Int(scaled))
    }

    static func replacing(_ request: BoneInferenceRequest, messages: [BoneInferenceMessage], output: Int? = nil,
                          continuation: BoneInferenceProviderContinuation? = nil, replaceContinuation: Bool = false) -> BoneInferenceRequest {
        .init(modelID: request.modelID, messages: messages, availableTools: request.availableTools,
              generationOptions: .init(temperature: request.generationOptions.temperature, maximumOutputTokens: output ?? request.generationOptions.maximumOutputTokens),
              responseFormat: request.responseFormat, outputConstraint: request.outputConstraint,
              providerContinuation: replaceContinuation ? continuation : request.providerContinuation, reasoningDisclosure: request.reasoningDisclosure)
    }
}
