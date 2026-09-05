import Foundation

public enum BoneAgentInferenceCheckpointKind: String, Codable, Equatable, Sendable {
    case finish, structured, toolCall, assistantTurn
}

/// 推理失败的安全分类；只保留固定类别和 HTTP 状态码，不携带错误文本或网络地址。
public enum BoneAgentInferenceFailureDiagnostic: Equatable, Sendable {
    case invalidCredential
    case invalidConfiguration
    case httpStatus(Int)
    case rateLimited
    case quotaExceeded
    case unsupportedModel
    case safetyBlocked
    case outputTruncated
    case firstEventTimedOut
    case idleTimedOut
    case network
    case invalidResponse
    case unknown
}

public enum BoneAgentProgress: Equatable, Sendable {
    case inferenceResponsePrepared(step: Int, kind: BoneAgentInferenceCheckpointKind)
    case inferenceFailed(BoneAgentInferenceFailureDiagnostic)
    /// Provider 协议失败的白名单形态；不携带正文、推理、Tool 参数或原始事件。
    case inferenceProtocolShapeFailed(BoneInferenceProtocolShapeDiagnostic)
    /// Tool 已通过定义、影响与 Schema 校验，即将申请执行预算；仅携带稳定 Tool ID。
    case toolExecutionPrepared(toolID: String)
    /// 仅携带 Schema 声明路径与固定规则，不携带 Tool 参数或未知模型键。
    case toolArgumentsRejected(toolID: String, mismatch: BoneToolSchemaMismatch)
    case toolResultPrepared(step: Int, ordinal: Int)
}

public struct BoneAgentProgressSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentProgress) async throws -> Void

    public init(_ receive: @escaping @Sendable (BoneAgentProgress) async throws -> Void = { _ in }) {
        receiveClosure = receive
    }

    public func receive(_ progress: BoneAgentProgress) async throws {
        try await receiveClosure(progress)
    }
}

public enum BoneWorkflowAgentStepTerminalState: String, Codable, Equatable, Sendable {
    case succeeded, failed, cancelled
}

public struct BoneWorkflowAgentStepCheckpoint: Codable, Equatable, Sendable {
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let state: BoneWorkflowStepState
    public let inferenceResponseCount: Int
    public let toolResultCount: Int
    public let pendingAuthorizationTicketID: BoneAuthorizationTicketID?
    public let cancellationPersisted: Bool
    public let terminalState: BoneWorkflowAgentStepTerminalState?
    public let persistenceRevision: UInt64
    public let leaseGeneration: UInt64

    public init(
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        state: BoneWorkflowStepState = .running,
        inferenceResponseCount: Int = 0,
        toolResultCount: Int = 0,
        pendingAuthorizationTicketID: BoneAuthorizationTicketID? = nil,
        cancellationPersisted: Bool = false,
        terminalState: BoneWorkflowAgentStepTerminalState? = nil,
        persistenceRevision: UInt64 = 0,
        leaseGeneration: UInt64 = 0
    ) {
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.state = state
        self.inferenceResponseCount = inferenceResponseCount
        self.toolResultCount = toolResultCount
        self.pendingAuthorizationTicketID = pendingAuthorizationTicketID
        self.cancellationPersisted = cancellationPersisted
        self.terminalState = terminalState
        self.persistenceRevision = persistenceRevision
        self.leaseGeneration = leaseGeneration
    }
}

public struct BoneWorkflowAgentStepCheckpointStore: Sendable {
    private let commitClosure: @Sendable (
        BoneWorkflowAgentStepCheckpoint,
        UInt64,
        UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint

    public init(_ commit: @escaping @Sendable (
        BoneWorkflowAgentStepCheckpoint,
        UInt64,
        UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint) {
        commitClosure = commit
    }

    public func commit(
        _ checkpoint: BoneWorkflowAgentStepCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint {
        try await commitClosure(checkpoint, expectedRevision, leaseGeneration)
    }
}

public enum BoneWorkflowAgentStepEventKind: String, Codable, Equatable, Sendable {
    case inferenceCheckpointed
    case toolResultCheckpointed
    case waitingForAuthorization
    case resumed
    case paused
    case succeeded
    case failed
    case cancelled
}

public struct BoneWorkflowAgentStepEvent: Codable, Equatable, Sendable {
    public let kind: BoneWorkflowAgentStepEventKind
    public init(kind: BoneWorkflowAgentStepEventKind) { self.kind = kind }
}

public struct BoneWorkflowAgentStepEventSink: Sendable {
    private let receiveClosure: @Sendable (BoneWorkflowAgentStepEvent) async -> Void

    public init(_ receive: @escaping @Sendable (BoneWorkflowAgentStepEvent) async -> Void = { _ in }) {
        receiveClosure = receive
    }

    public func receive(_ event: BoneWorkflowAgentStepEvent) async {
        await receiveClosure(event)
    }
}

public enum BoneWorkflowAgentStepError: Error, Codable, Equatable, Sendable {
    case terminalState
    case invalidState
    case authorizationTicketMismatch
}

public actor BoneWorkflowAgentStepController {
    public private(set) var checkpoint: BoneWorkflowAgentStepCheckpoint
    private let persistence: BoneWorkflowAgentStepCheckpointStore
    private let eventSink: BoneWorkflowAgentStepEventSink

    public init(
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        persistence: BoneWorkflowAgentStepCheckpointStore,
        eventSink: BoneWorkflowAgentStepEventSink = .init()
    ) throws {
        checkpoint = .init(runID: runID, stepID: stepID, attemptID: attemptID)
        self.persistence = persistence
        self.eventSink = eventSink
    }

    public init(
        restoring checkpoint: BoneWorkflowAgentStepCheckpoint,
        persistence: BoneWorkflowAgentStepCheckpointStore,
        eventSink: BoneWorkflowAgentStepEventSink = .init()
    ) throws {
        try Self.validate(checkpoint)
        self.checkpoint = checkpoint
        self.persistence = persistence
        self.eventSink = eventSink
    }

    public func receive(_ progress: BoneAgentProgress) async throws {
        try ensureMutableRunning()
        let next: BoneWorkflowAgentStepCheckpoint
        let event: BoneWorkflowAgentStepEventKind
        switch progress {
        case .inferenceFailed, .inferenceProtocolShapeFailed, .toolExecutionPrepared, .toolArgumentsRejected:
            // 推理/预执行诊断不是可恢复业务检查点，不写持久状态。
            return
        case let .inferenceResponsePrepared(step, _):
            guard step > 0, step >= checkpoint.inferenceResponseCount else {
                throw BoneWorkflowAgentStepError.invalidState
            }
            next = copy(inferenceResponseCount: checkpoint.inferenceResponseCount + 1)
            event = .inferenceCheckpointed
        case let .toolResultPrepared(step, ordinal):
            guard step > 0, ordinal >= 0, checkpoint.inferenceResponseCount > 0 else {
                throw BoneWorkflowAgentStepError.invalidState
            }
            next = copy(toolResultCount: checkpoint.toolResultCount + 1)
            event = .toolResultCheckpointed
        }
        try await commit(next, event: event)
    }

    public func waitForAuthorization(ticketID: BoneAuthorizationTicketID) async throws {
        try ensureMutableRunning()
        try await commit(copy(state: .waiting, pendingAuthorizationTicketID: ticketID), event: .waitingForAuthorization)
    }

    public func resumeAfterAuthorization(ticketID: BoneAuthorizationTicketID) async throws {
        try ensureNotTerminal()
        guard checkpoint.state == .waiting,
              checkpoint.pendingAuthorizationTicketID == ticketID else {
            throw BoneWorkflowAgentStepError.authorizationTicketMismatch
        }
        try await commit(copy(state: .running, clearAuthorizationTicket: true), event: .resumed)
    }

    public func pause() async throws {
        try ensureMutableRunning()
        try await commit(copy(state: .paused), event: .paused)
    }

    public func resume() async throws {
        try ensureNotTerminal()
        guard checkpoint.state == .paused else { throw BoneWorkflowAgentStepError.invalidState }
        try await commit(copy(state: .running), event: .resumed)
    }

    public func cancel() async throws {
        try ensureNotTerminal()
        try await commit(copy(state: .cancelled, clearAuthorizationTicket: true, cancellationPersisted: true, terminalState: .cancelled), event: .cancelled)
    }

    /// Waiting steps may fail or cancel, but must explicitly resume authorization before succeeding.
    public func finish(_ terminalState: BoneWorkflowAgentStepTerminalState) async throws {
        try ensureNotTerminal()
        guard terminalState != .succeeded || checkpoint.state != .waiting else {
            throw BoneWorkflowAgentStepError.invalidState
        }
        let state: BoneWorkflowStepState
        let event: BoneWorkflowAgentStepEventKind
        switch terminalState {
        case .succeeded: state = .succeeded; event = .succeeded
        case .failed: state = .failed; event = .failed
        case .cancelled: state = .cancelled; event = .cancelled
        }
        try await commit(copy(state: state, clearAuthorizationTicket: true, cancellationPersisted: terminalState == .cancelled, terminalState: terminalState), event: event)
    }

    public nonisolated func progressSink() -> BoneAgentProgressSink {
        BoneAgentProgressSink { [weak self] progress in
            guard let self else { throw CancellationError() }
            try await self.receive(progress)
        }
    }

    private func commit(_ next: BoneWorkflowAgentStepCheckpoint, event: BoneWorkflowAgentStepEventKind) async throws {
        // Reject inconsistent candidates before the Host can persist them.
        try Self.validate(next)
        let stored = try await persistence.commit(
            next,
            expectedRevision: checkpoint.persistenceRevision,
            leaseGeneration: checkpoint.leaseGeneration
        )
        try Self.validate(stored)
        guard stored.runID == next.runID,
              stored.stepID == next.stepID,
              stored.attemptID == next.attemptID,
              stored.state == next.state,
              stored.inferenceResponseCount == next.inferenceResponseCount,
              stored.toolResultCount == next.toolResultCount,
              stored.pendingAuthorizationTicketID == next.pendingAuthorizationTicketID,
              stored.cancellationPersisted == next.cancellationPersisted,
              stored.terminalState == next.terminalState,
              stored.leaseGeneration == checkpoint.leaseGeneration,
              stored.persistenceRevision == checkpoint.persistenceRevision + 1 else {
            throw BoneWorkflowAgentStepError.invalidState
        }
        checkpoint = stored
        await eventSink.receive(.init(kind: event))
    }

    private static func validate(_ checkpoint: BoneWorkflowAgentStepCheckpoint) throws {
        guard checkpoint.inferenceResponseCount >= 0,
              checkpoint.toolResultCount >= 0 else {
            throw BoneWorkflowAgentStepError.invalidState
        }
        let expectedTerminal: BoneWorkflowAgentStepTerminalState?
        switch checkpoint.state {
        case .succeeded: expectedTerminal = .succeeded
        case .failed: expectedTerminal = .failed
        case .cancelled: expectedTerminal = .cancelled
        case .commitUncertain:
            // 自动执行在此终止，但保留无业务终态的 checkpoint，等待 Host 显式调和。
            expectedTerminal = nil
        case .pending, .ready, .running, .waiting, .paused, .skipped:
            expectedTerminal = nil
        }
        guard checkpoint.terminalState == expectedTerminal,
              checkpoint.cancellationPersisted == (checkpoint.state == .cancelled),
              (checkpoint.state == .waiting) == (checkpoint.pendingAuthorizationTicketID != nil) else {
            throw BoneWorkflowAgentStepError.invalidState
        }
    }

    private func ensureMutableRunning() throws {
        try ensureNotTerminal()
        guard checkpoint.state == .running else { throw BoneWorkflowAgentStepError.invalidState }
    }

    private func ensureNotTerminal() throws {
        guard checkpoint.terminalState == nil,
              checkpoint.state != .commitUncertain else {
            throw BoneWorkflowAgentStepError.terminalState
        }
    }

    private func copy(
        state: BoneWorkflowStepState? = nil,
        inferenceResponseCount: Int? = nil,
        toolResultCount: Int? = nil,
        pendingAuthorizationTicketID: BoneAuthorizationTicketID? = nil,
        clearAuthorizationTicket: Bool = false,
        cancellationPersisted: Bool? = nil,
        terminalState: BoneWorkflowAgentStepTerminalState? = nil
    ) -> BoneWorkflowAgentStepCheckpoint {
        .init(
            runID: checkpoint.runID,
            stepID: checkpoint.stepID,
            attemptID: checkpoint.attemptID,
            state: state ?? checkpoint.state,
            inferenceResponseCount: inferenceResponseCount ?? checkpoint.inferenceResponseCount,
            toolResultCount: toolResultCount ?? checkpoint.toolResultCount,
            pendingAuthorizationTicketID: clearAuthorizationTicket ? nil : (pendingAuthorizationTicketID ?? checkpoint.pendingAuthorizationTicketID),
            cancellationPersisted: cancellationPersisted ?? checkpoint.cancellationPersisted,
            terminalState: terminalState ?? checkpoint.terminalState,
            persistenceRevision: checkpoint.persistenceRevision,
            leaseGeneration: checkpoint.leaseGeneration
        )
    }
}
