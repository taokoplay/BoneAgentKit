import Foundation

/// A measured request projection, distinct from Provider usage and lifetime consumption.
public struct BoneAgentContextTokens: Equatable, Sendable {
    public enum Stage: Equatable, Sendable {
        case unmanaged, beforeCompaction, compactionCandidate, ready, rejected
    }
    public enum Source: Equatable, Sendable { case estimate, tokenizer, unavailable }
    public let modelID: String
    public let step: Int
    public let stage: Stage
    public let source: Source
    /// Includes text, every image occurrence, tools, output constraints and continuation.
    public let inputTokens: Int?
    public let inputTokensBeforeCompaction: Int?
    public let imageCount: Int
    public let contextWindowTokens: Int?
    public let availableInputTokens: Int?
    public let reservedOutputTokens: Int?
    public let protocolReserveTokens: Int?
    public let safetyMarginTokens: Int?
    public let compactionTriggerTokens: Int?
    public let compactionTargetTokens: Int?
    public let revision: UInt64

    /// Fraction of usable INPUT capacity, not the whole context window. May exceed 1 on rejection.
    public var utilization: Double? {
        guard let inputTokens, let limit = availableInputTokens, limit > 0 else { return nil }
        return Double(inputTokens) / Double(limit)
    }
    public var remainingInputTokens: Int? {
        guard let inputTokens, let limit = availableInputTokens else { return nil }
        return max(0, limit - inputTokens)
    }
    public var tokensUntilCompaction: Int? {
        guard let inputTokens, let trigger = compactionTriggerTokens else { return nil }
        return max(0, trigger - inputTokens)
    }
}

/// One Engine invocation attempt. Usage snapshots are cumulative within this request, never deltas.
public struct BoneAgentTokenRequest: Equatable, Sendable {
    public enum Purpose: Equatable, Sendable { case business, summary }
    public enum State: Equatable, Sendable { case inFlight, responseReceived, failed, cancelled }
    public let id: UUID
    public let modelID: String
    public let step: Int
    public let purpose: Purpose
    public internal(set) var state: State
    /// Last observed provisional usage; retained after interruption, excluded from finalized totals.
    public internal(set) var provisionalUsage: BoneInferenceUsage?
    /// Usage from the Engine's complete response. Nil is unknown, not zero.
    public internal(set) var finalUsage: BoneInferenceUsage?
    public internal(set) var durationSeconds: TimeInterval? = nil
    public internal(set) var timeToFirstTokenSeconds: TimeInterval? = nil
    public internal(set) var outputDurationSeconds: TimeInterval? = nil
    public var outputTokensPerSecond: Double? {
        guard state == .responseReceived, let finalUsage, let duration = outputDurationSeconds, duration > 0 else { return nil }
        let value = Double(finalUsage.outputTokens) / duration
        return value.isFinite ? value : nil
    }
}

public struct BoneAgentTokenTotals: Equatable, Sendable {
    public let requestCount: Int
    public let responseCount: Int
    public let reportedResponseCount: Int
    /// Sums only final reports. Field semantics remain those of BoneInferenceUsage/each Provider.
    public let knownUsage: BoneInferenceUsage?
    public let overflowed: Bool
    public var unreportedResponseCount: Int { responseCount - reportedResponseCount }
    public var unresolvedRequestCount: Int { requestCount - responseCount }
    public var isComplete: Bool {
        requestCount > 0 && reportedResponseCount == requestCount && !overflowed
    }

    init(requests: [BoneAgentTokenRequest]) {
        var summary = BoneUsageSummary()
        for request in requests { summary.record(request) }
        self.init(summary: summary)
    }
    init(summary: BoneUsageSummary) {
        requestCount = summary.requests; responseCount = summary.responses
        reportedResponseCount = summary.reported; overflowed = summary.overflowed
        knownUsage = summary.reported == 0 ? nil : .init(inputTokens: summary.input, outputTokens: summary.output,
            cachedInputTokens: summary.cached, reasoningTokens: summary.reasoning,
            cacheCreationInputTokens: summary.cacheCreation)
    }
}

/// Safe bounded observation. Aggregate totals include all requests, even when old details are omitted.
public struct BoneAgentTokenSnapshot: Equatable, Sendable {
    public let runID: UUID
    public let sequence: UInt64
    public let context: BoneAgentContextTokens?
    public let summaryContext: BoneAgentContextTokens?
    /// Recent completed requests plus every in-flight request, not a durable full history.
    public let requests: [BoneAgentTokenRequest]
    public let terminalState: BoneAgentRunTerminalState?
    public let toolTimings: [BoneAgentToolTiming]
    public let toolWallDurationSeconds: TimeInterval?
    let aggregate: BoneStatisticsSummary
    let modelUsage: [String: BoneUsageSummary]
    /// Requests whose model-specific breakdown exceeds the configured model count cap.
    public let omittedModelRequestCount: Int
    public var omittedRequestCount: Int { max(0, total.requestCount - requests.count) }
    public var omittedToolTimingCount: Int { max(0, aggregate.toolCount - toolTimings.count) }
    public var statistics: BoneAgentStatistics { .init(summary: aggregate, isHistoryComplete: true) }
    public var latestRequest: BoneAgentTokenRequest? { requests.last }
    public var total: BoneAgentTokenTotals { .init(summary: aggregate.totalUsage) }
    public var business: BoneAgentTokenTotals { .init(summary: aggregate.business.usage) }
    public var summaries: BoneAgentTokenTotals { .init(summary: aggregate.summaries.usage) }
    public func totals(forModelID modelID: String) -> BoneAgentTokenTotals {
        .init(summary: modelUsage[modelID] ?? .init())
    }
    public func hasModelBreakdown(for modelID: String) -> Bool { modelUsage[modelID] != nil }
}

/// Awaited observation, serialized with statusSink per Run. Do not wait for the same Run in this callback.
public struct BoneAgentTokenSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentTokenSnapshot) async -> Void
    public init(_ receive: @escaping @Sendable (BoneAgentTokenSnapshot) async -> Void = { _ in }) {
        receiveClosure = receive
    }
    public func receive(_ snapshot: BoneAgentTokenSnapshot) async { await receiveClosure(snapshot) }
}

/// Actor-confined ledger: O(1) updates, fixed retained details, only in-flight clocks remain mutable.
struct BoneAgentTokenLedger {
    var sequence: UInt64 = 0
    var context: BoneAgentContextTokens?
    var summaryContext: BoneAgentContextTokens?
    var terminalState: BoneAgentRunTerminalState?
    private let policy: BoneAgentObservationPolicy
    private var recentRequests: BoneObservationRing<BoneAgentTokenRequest>
    private var recentTools: BoneObservationRing<BoneAgentToolTiming>
    private var completed = BoneStatisticsSummary()
    private var modelUsage: [String: BoneUsageSummary] = [:]
    private var omittedModelRequests = 0
    private var activeRequests: [UUID: BoneAgentTokenRequest] = [:]
    private var activeOrder: [UUID] = []
    private var providerUsageIDs = Set<UUID>()
    var requestClocks: [UUID: BoneAgentRequestClock] = [:]
    private var activeTools: [UUID: BoneAgentToolClock] = [:]
    private var toolWallStart: TimeInterval?

    init(policy: BoneAgentObservationPolicy = .init()) {
        self.policy = policy
        recentRequests = .init(limit: policy.maximumRequestDetails)
        recentTools = .init(limit: policy.maximumToolDetails)
    }
    var inFlightRequests: [BoneAgentTokenRequest] { activeOrder.compactMap { activeRequests[$0] } }
    var retainedRequestCount: Int { recentRequests.count + activeRequests.count }
    var retainedToolCount: Int { recentTools.count + activeTools.count }
    var retainedModelCount: Int { modelUsage.count }
    func isInFlight(_ id: UUID) -> Bool { activeRequests[id] != nil }

    mutating func begin(id: UUID, modelID: String, step: Int, purpose: BoneAgentTokenRequest.Purpose, now: TimeInterval) {
        guard terminalState == nil, activeRequests[id] == nil else { return }
        requestClocks[id] = .init(started: now)
        activeOrder.append(id)
        activeRequests[id] = .init(id: id, modelID: modelID, step: step, purpose: purpose,
                                  state: .inFlight, provisionalUsage: nil, finalUsage: nil)
        if modelUsage[modelID] == nil, modelUsage.count < policy.maximumModelBreakdowns { modelUsage[modelID] = .init() }
    }
    mutating func observe(_ usage: BoneInferenceUsage, id: UUID, provider: Bool) -> Bool {
        guard terminalState == nil, var request = activeRequests[id], let valid = try? usage.validated() else { return false }
        if provider { providerUsageIDs.insert(id) }
        else if providerUsageIDs.contains(id) { return false }
        guard request.provisionalUsage != valid else { return false }
        request.provisionalUsage = valid
        activeRequests[id] = request
        return true
    }
    mutating func observeTiming(_ event: BoneInferenceTelemetryEvent, id: UUID, now: TimeInterval) -> Bool {
        guard terminalState == nil, isInFlight(id), var clock = requestClocks[id] else { return false }
        let before = clock
        clock.observe(event, now: now)
        guard clock != before else { return false }
        requestClocks[id] = clock
        return true
    }
    mutating func finish(id: UUID, state: BoneAgentTokenRequest.State, usage: BoneInferenceUsage?, now: TimeInterval) -> Bool {
        guard terminalState == nil, state != .inFlight, var request = activeRequests.removeValue(forKey: id) else { return false }
        request.state = state
        request.finalUsage = state == .responseReceived ? usage.flatMap { try? $0.validated() } : nil
        requestClocks[id]?.ended = now
        request = measured(request, now: now)
        completed.record(request)
        if var model = modelUsage[request.modelID] { model.record(request); modelUsage[request.modelID] = model }
        else { omittedModelRequests = BoneObservationMath.add(omittedModelRequests, 1) }
        recentRequests.append(request)
        requestClocks.removeValue(forKey: id); providerUsageIDs.remove(id)
        activeOrder.removeAll { $0 == id }
        return true
    }
    private func measured(_ request: BoneAgentTokenRequest, now: TimeInterval) -> BoneAgentTokenRequest {
        guard let timing = requestClocks[request.id] else { return request }
        var copy = request
        copy.durationSeconds = BoneAgentRequestClock.duration(timing.started, timing.ended ?? now)
        if timing.live {
            copy.timeToFirstTokenSeconds = BoneAgentRequestClock.duration(timing.transportStarted, timing.firstOutput)
            copy.outputDurationSeconds = BoneAgentRequestClock.duration(timing.firstOutput, timing.streamEnded)
        }
        return copy
    }
    mutating func beginTool(call: BoneInferenceToolCall, step: Int, now: TimeInterval) -> UUID {
        let id = UUID()
        if activeTools.isEmpty { toolWallStart = now }
        activeTools[id] = .init(id: id, callID: call.id, toolID: call.toolID, step: step, started: now)
        return id
    }
    mutating func finishTool(_ id: UUID, now: TimeInterval) {
        guard var clock = activeTools.removeValue(forKey: id) else { return }
        clock.ended = now
        let timing = clock.snapshot(now: now)
        completed.toolCount = BoneObservationMath.add(completed.toolCount, 1)
        completed.toolDuration = BoneObservationMath.duration(completed.toolDuration, timing.durationSeconds)
        if timing.durationSeconds == nil { completed.toolWallDuration = nil }
        recentTools.append(timing)
        if activeTools.isEmpty {
            completed.toolWallDuration = BoneObservationMath.duration(completed.toolWallDuration,
                BoneAgentRequestClock.duration(toolWallStart, now))
            toolWallStart = nil
        }
    }
    mutating func snapshot(runID: UUID, now: TimeInterval, advance: Bool = true) -> BoneAgentTokenSnapshot {
        if advance { sequence += 1 }
        var aggregate = completed
        aggregate.rounds = 1
        aggregate.successfulRounds = terminalState == .succeeded ? 1 : 0
        var models = modelUsage
        var omittedModels = omittedModelRequests
        var details = recentRequests.values
        for id in activeOrder {
            guard let request = activeRequests[id] else { continue }
            let value = measured(request, now: now)
            details.append(value); aggregate.record(value)
            if var model = models[value.modelID] { model.record(value); models[value.modelID] = model }
            else { omittedModels = BoneObservationMath.add(omittedModels, 1) }
        }
        var tools = recentTools.values
        for clock in activeTools.values.sorted(by: { $0.started == $1.started ? $0.callID < $1.callID : $0.started < $1.started }) {
            let timing = clock.snapshot(now: now)
            tools.append(timing)
            aggregate.toolCount = BoneObservationMath.add(aggregate.toolCount, 1)
            aggregate.toolDuration = BoneObservationMath.duration(aggregate.toolDuration, timing.durationSeconds)
            if timing.durationSeconds == nil { aggregate.toolWallDuration = nil }
        }
        if !activeTools.isEmpty {
            aggregate.toolWallDuration = BoneObservationMath.duration(aggregate.toolWallDuration,
                BoneAgentRequestClock.duration(toolWallStart, now))
        }
        return .init(runID: runID, sequence: sequence, context: context, summaryContext: summaryContext,
            requests: details, terminalState: terminalState, toolTimings: tools,
            toolWallDurationSeconds: aggregate.toolWallDuration, aggregate: aggregate, modelUsage: models,
            omittedModelRequestCount: omittedModels)
    }
}
