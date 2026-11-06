import Foundation

/// UI observation of one Agent Run; not a durable checkpoint or a retry/authorization permit.
/// Contains no prompts, reasoning, tool arguments/results, image references or raw errors.
public struct BoneAgentStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case preparingInput
        case checkingBudget
        case compactingContext
        case summarizingContext
        case resolvingImages
        /// Engine invocation is in flight; a custom engine may also be preparing its request.
        case waitingForModel
        /// Only emitted when the Provider reports reasoning activity; never inferred from elapsed time.
        case reasoning
        case generatingResponse
        case generatingToolCall
        case validatingResponse
        case preparingTools
        case executingTools
        case processingToolResults
        /// Success means the requested Agent boundary was reached, not that an external commit succeeded.
        case finished(BoneAgentRunTerminalState)
    }

    public struct Tool: Equatable, Sendable {
        public enum Phase: Equatable, Sendable { case preparing, executing }
        public let callID: String
        public let toolID: String
        public let ordinal: Int
        public let phase: Phase
    }

    public let runID: UUID
    public let sequence: UInt64
    /// One-based inference step, or nil during initial validation.
    public let step: Int?
    public let phase: Phase
    /// All in-flight tool operations, sorted by ordinal. Finishing one does not clear the others.
    public let activeTools: [Tool]
    public let tokens: BoneAgentTokenSnapshot
    public var isTerminal: Bool {
        if case .finished = phase { return true }
        return false
    }
}

/// Ordered, nonthrowing observation shared by run, runEvents and Conversation.send.
/// Callbacks are awaited and serialized per Run, including parallel tools. Keep them short;
/// they may read currentStatus but must not wait for the same Run to finish.
public struct BoneAgentStatusSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentStatus) async -> Void
    public init(_ receive: @escaping @Sendable (BoneAgentStatus) async -> Void = { _ in }) {
        receiveClosure = receive
    }
    public func receive(_ status: BoneAgentStatus) async { await receiveClosure(status) }
}

/// One instance per accepted Run. Snapshot mutations are atomic; delivery is serialized
/// across suspension points so a slow observer cannot reorder parallel tool updates.
actor BoneAgentStatusReporter {
    private let runID = UUID()
    private let sink: BoneAgentStatusSink
    private let tokenSink: BoneAgentTokenSink
    private let clock: @Sendable () -> TimeInterval
    private(set) var current: BoneAgentStatus?
    private var ledger: BoneAgentTokenLedger
    private let policy: BoneAgentObservationPolicy
    private var lastTokenNotification: TimeInterval?
    private var tools: [String: BoneAgentStatus.Tool] = [:]
    private var delivering = false
    private var pending: [(BoneAgentStatus, CheckedContinuation<Void, Never>)?] = []
    private var providerReportsActivity = false
    private var inferenceID: UUID?

    init(sink: BoneAgentStatusSink, tokenSink: BoneAgentTokenSink = .init(),
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         policy: BoneAgentObservationPolicy = .init()) {
        self.sink = sink; self.tokenSink = tokenSink; self.clock = clock; self.policy = policy
        ledger = .init(policy: policy)
    }
    var currentTokens: BoneAgentTokenSnapshot? {
        guard let current else { return nil }
        if current.isTerminal { return current.tokens }
        var copy = ledger
        return copy.snapshot(runID: runID, now: clock(), advance: false)
    }

    func transition(_ phase: BoneAgentStatus.Phase, step: Int? = nil, tokensChanged: Bool = false) async {
        guard current?.isTerminal != true else { return }
        let nextStep = step ?? current?.step
        if phase == .checkingBudget, ledger.context?.step != nextStep {
            ledger.context = nil; ledger.summaryContext = nil
        }
        if case .finished(let terminal) = phase {
            let now = clock()
            for request in ledger.inFlightRequests {
                _ = ledger.finish(id: request.id, state: terminal == .cancelled ? .cancelled : .failed, usage: nil, now: now)
            }
            ledger.terminalState = terminal
            tools.removeAll(); inferenceID = nil
        }
        let active = tools.values.sorted { $0.ordinal == $1.ordinal ? $0.callID < $1.callID : $0.ordinal < $1.ordinal }
        guard tokensChanged || current?.phase != phase || current?.step != nextStep || current?.activeTools != active else { return }
        let value = BoneAgentStatus(runID: runID, sequence: (current?.sequence ?? 0) + 1,
            step: nextStep, phase: phase, activeTools: active, tokens: ledger.snapshot(runID: runID, now: clock()))
        current = value
        lastTokenNotification = clock()
        if delivering {
            await withCheckedContinuation { pending.append((value, $0)) }
            return
        }
        delivering = true
        await deliver(value)
        var head = 0
        while head < pending.count {
            guard let (next, waiter) = pending[head] else { head += 1; continue }
            pending[head] = nil // Release each delivered snapshot even during sustained parallel activity.
            head += 1
            await deliver(next)
            waiter.resume()
            if head >= 64 { pending.removeFirst(head); head = 0 }
        }
        pending.removeAll(keepingCapacity: false)
        delivering = false
    }
    private func deliver(_ value: BoneAgentStatus) async {
        await sink.receive(value)
        await tokenSink.receive(value.tokens)
    }
    private func tokensChanged(force: Bool = true) async {
        let now = clock()
        if !force, let last = lastTokenNotification, now.isFinite, last.isFinite,
           now >= last, now - last < policy.minimumTokenUpdateInterval { return }
        await transition(current?.phase ?? .preparingInput, tokensChanged: true)
    }
    func contextTokens(_ value: BoneAgentContextTokens, summary: Bool = false) async {
        guard current?.isTerminal != true else { return }
        if summary {
            guard ledger.summaryContext != value else { return }
            ledger.summaryContext = value
        } else {
            guard ledger.context != value else { return }
            ledger.context = value
        }
        await tokensChanged(force: value.stage != .compactionCandidate)
    }
    func beginTokenRequest(modelID: String, step: Int, purpose: BoneAgentTokenRequest.Purpose) async -> UUID {
        let id = UUID()
        ledger.begin(id: id, modelID: modelID, step: step, purpose: purpose, now: clock())
        await tokensChanged()
        return id
    }
    func finishTokenRequest(_ id: UUID, state: BoneAgentTokenRequest.State, usage: BoneInferenceUsage?) async {
        guard ledger.finish(id: id, state: state, usage: usage, now: clock()) else { return }
        await tokensChanged()
    }
    func telemetry(_ event: BoneInferenceTelemetryEvent, id: UUID) async {
        guard current?.isTerminal != true, ledger.isInFlight(id) else { return }
        if case .usage(let usage) = event {
            guard ledger.observe(usage, id: id, provider: true) else { return }
        } else {
            guard ledger.observeTiming(event, id: id, now: clock()) else { return }
        }
        // Waiting status was already published. Do not add an observer pause
        // between the transport timing origin and the actual send.
        if case .requestStarted = event { return }
        await tokensChanged(force: false)
    }
    func streamUsage(_ usage: BoneInferenceUsage, id: UUID) async {
        guard ledger.observe(usage, id: id, provider: false) else { return }
        await tokensChanged(force: false)
    }

    func beginInference(step: Int, modelID: String = "") async -> UUID {
        let id = UUID()
        inferenceID = id; providerReportsActivity = false
        ledger.begin(id: id, modelID: modelID, step: step, purpose: .business, now: clock())
        await transition(.waitingForModel, step: step, tokensChanged: true)
        return id
    }
    func endInference(_ id: UUID) { if inferenceID == id { inferenceID = nil } }
    func inferenceActivity(_ activity: BoneInferenceActivity, id: UUID) async {
        guard inferenceID == id else { return }
        providerReportsActivity = true
        await apply(activity)
    }
    func streamActivity(_ activity: BoneInferenceActivity, id: UUID) async {
        guard inferenceID == id, !providerReportsActivity else { return }
        await apply(activity)
    }
    func streamReasoningCompleted(id: UUID) async {
        guard inferenceID == id, !providerReportsActivity, current?.phase == .reasoning else { return }
        await transition(.waitingForModel)
    }
    private func apply(_ activity: BoneInferenceActivity) async {
        let phase: BoneAgentStatus.Phase
        switch activity {
        case .resolvingImages: phase = .resolvingImages
        case .waitingForModel: phase = .waitingForModel
        case .reasoning: phase = .reasoning
        case .generatingResponse: phase = .generatingResponse
        case .generatingToolCall: phase = .generatingToolCall
        case .validatingResponse: phase = .validatingResponse
        }
        await transition(phase)
    }

    func withTool<Value: Sendable>(_ call: BoneInferenceToolCall, step: Int,
                                  operation: @Sendable () async throws -> Value) async throws -> Value {
        guard current?.isTerminal != true else { throw CancellationError() }
        tools[call.id] = .init(callID: call.id, toolID: call.toolID, ordinal: call.ordinal, phase: .preparing)
        await toolPhase(step: step)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            tools.removeValue(forKey: call.id)
            await toolPhase(step: step)
            return result
        } catch {
            tools.removeValue(forKey: call.id)
            await toolPhase(step: step)
            throw error
        }
    }
    func measureTool<Value: Sendable>(_ call: BoneInferenceToolCall, step: Int,
                                     operation: @Sendable () async throws -> Value) async throws -> Value {
        await toolExecuting(call, step: step)
        try Task.checkCancellation()
        let id = ledger.beginTool(call: call, step: step, now: clock())
        do {
            let result = try await operation()
            ledger.finishTool(id, now: clock())
            return result
        } catch {
            ledger.finishTool(id, now: clock())
            throw error
        }
    }
    func toolExecuting(_ call: BoneInferenceToolCall, step: Int) async {
        guard tools[call.id] != nil else { return }
        tools[call.id] = .init(callID: call.id, toolID: call.toolID, ordinal: call.ordinal, phase: .executing)
        await toolPhase(step: step)
    }
    private func toolPhase(step: Int) async {
        await transition(tools.isEmpty ? .processingToolResults :
            (tools.values.contains { $0.phase == .executing } ? .executingTools : .preparingTools), step: step)
    }
}
