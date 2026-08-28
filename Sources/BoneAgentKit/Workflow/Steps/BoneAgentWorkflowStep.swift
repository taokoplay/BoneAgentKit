import Foundation

public enum BoneAgentInferenceCheckpointKind: String, Codable, Equatable, Sendable {
    case finish, structured, toolCall, assistantTurn
}

public enum BoneAgentProgress: Equatable, Sendable {
    case inferenceResponsePrepared(step: Int, kind: BoneAgentInferenceCheckpointKind)
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

public enum BoneAgentWorkflowStepTerminalState: String, Codable, Equatable, Sendable {
    case succeeded, failed, cancelled
}

public struct BoneAgentWorkflowStepCheckpoint: Codable, Equatable, Sendable {
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let state: BoneWorkflowStepState
    public let inferenceResponseCount: Int
    public let toolResultCount: Int
    public let pendingAuthorizationTicketID: BoneAuthorizationTicketID?
    public let cancellationPersisted: Bool
    public let terminalState: BoneAgentWorkflowStepTerminalState?
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
        terminalState: BoneAgentWorkflowStepTerminalState? = nil,
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

public struct BoneAgentWorkflowStepPersistence: Sendable {
    private let commitClosure: @Sendable (
        BoneAgentWorkflowStepCheckpoint,
        UInt64,
        UInt64
    ) async throws -> BoneAgentWorkflowStepCheckpoint

    public init(_ commit: @escaping @Sendable (
        BoneAgentWorkflowStepCheckpoint,
        UInt64,
        UInt64
    ) async throws -> BoneAgentWorkflowStepCheckpoint) {
        commitClosure = commit
    }

    public func commit(
        _ checkpoint: BoneAgentWorkflowStepCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentWorkflowStepCheckpoint {
        try await commitClosure(checkpoint, expectedRevision, leaseGeneration)
    }
}

public enum BoneAgentWorkflowStepEventKind: String, Codable, Equatable, Sendable {
    case inferenceCheckpointed
    case toolResultCheckpointed
    case waitingForAuthorization
    case resumed
    case paused
    case succeeded
    case failed
    case cancelled
}

public struct BoneAgentWorkflowStepEvent: Codable, Equatable, Sendable {
    public let kind: BoneAgentWorkflowStepEventKind
    public init(kind: BoneAgentWorkflowStepEventKind) { self.kind = kind }
}

public struct BoneAgentWorkflowStepEventSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentWorkflowStepEvent) async -> Void

    public init(_ receive: @escaping @Sendable (BoneAgentWorkflowStepEvent) async -> Void = { _ in }) {
        receiveClosure = receive
    }

    public func receive(_ event: BoneAgentWorkflowStepEvent) async {
        await receiveClosure(event)
    }
}

public enum BoneAgentWorkflowStepError: Error, Codable, Equatable, Sendable {
    case terminalState
    case invalidState
    case authorizationTicketMismatch
}

public actor BoneAgentWorkflowStepController {
    public private(set) var checkpoint: BoneAgentWorkflowStepCheckpoint
    private let persistence: BoneAgentWorkflowStepPersistence
    private let eventSink: BoneAgentWorkflowStepEventSink

    public init(
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        persistence: BoneAgentWorkflowStepPersistence,
        eventSink: BoneAgentWorkflowStepEventSink = .init()
    ) throws {
        checkpoint = .init(runID: runID, stepID: stepID, attemptID: attemptID)
        self.persistence = persistence
        self.eventSink = eventSink
    }

    public init(
        restoring checkpoint: BoneAgentWorkflowStepCheckpoint,
        persistence: BoneAgentWorkflowStepPersistence,
        eventSink: BoneAgentWorkflowStepEventSink = .init()
    ) throws {
        try Self.validate(checkpoint)
        self.checkpoint = checkpoint
        self.persistence = persistence
        self.eventSink = eventSink
    }

    public func receive(_ progress: BoneAgentProgress) async throws {
        try ensureMutableRunning()
        let next: BoneAgentWorkflowStepCheckpoint
        let event: BoneAgentWorkflowStepEventKind
        switch progress {
        case let .inferenceResponsePrepared(step, _):
            guard step > 0, step >= checkpoint.inferenceResponseCount else {
                throw BoneAgentWorkflowStepError.invalidState
            }
            next = copy(inferenceResponseCount: checkpoint.inferenceResponseCount + 1)
            event = .inferenceCheckpointed
        case let .toolResultPrepared(step, ordinal):
            guard step > 0, ordinal >= 0, checkpoint.inferenceResponseCount > 0 else {
                throw BoneAgentWorkflowStepError.invalidState
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
            throw BoneAgentWorkflowStepError.authorizationTicketMismatch
        }
        try await commit(copy(state: .running, clearAuthorizationTicket: true), event: .resumed)
    }

    public func pause() async throws {
        try ensureMutableRunning()
        try await commit(copy(state: .paused), event: .paused)
    }

    public func resume() async throws {
        try ensureNotTerminal()
        guard checkpoint.state == .paused else { throw BoneAgentWorkflowStepError.invalidState }
        try await commit(copy(state: .running), event: .resumed)
    }

    public func cancel() async throws {
        try ensureNotTerminal()
        try await commit(copy(state: .cancelled, cancellationPersisted: true, terminalState: .cancelled), event: .cancelled)
    }

    public func finish(_ terminalState: BoneAgentWorkflowStepTerminalState) async throws {
        try ensureNotTerminal()
        let state: BoneWorkflowStepState
        let event: BoneAgentWorkflowStepEventKind
        switch terminalState {
        case .succeeded: state = .succeeded; event = .succeeded
        case .failed: state = .failed; event = .failed
        case .cancelled: state = .cancelled; event = .cancelled
        }
        try await commit(copy(state: state, cancellationPersisted: terminalState == .cancelled, terminalState: terminalState), event: event)
    }

    public nonisolated func progressSink() -> BoneAgentProgressSink {
        BoneAgentProgressSink { [weak self] progress in
            guard let self else { throw CancellationError() }
            try await self.receive(progress)
        }
    }

    private func commit(_ next: BoneAgentWorkflowStepCheckpoint, event: BoneAgentWorkflowStepEventKind) async throws {
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
            throw BoneAgentWorkflowStepError.invalidState
        }
        checkpoint = stored
        await eventSink.receive(.init(kind: event))
    }

    private static func validate(_ checkpoint: BoneAgentWorkflowStepCheckpoint) throws {
        guard checkpoint.inferenceResponseCount >= 0,
              checkpoint.toolResultCount >= 0 else {
            throw BoneAgentWorkflowStepError.invalidState
        }
        let expectedTerminal: BoneAgentWorkflowStepTerminalState?
        switch checkpoint.state {
        case .succeeded: expectedTerminal = .succeeded
        case .failed: expectedTerminal = .failed
        case .cancelled: expectedTerminal = .cancelled
        case .commitUncertain:
            throw BoneAgentWorkflowStepError.invalidState
        case .pending, .ready, .running, .waiting, .paused, .skipped:
            expectedTerminal = nil
        }
        guard checkpoint.terminalState == expectedTerminal,
              checkpoint.cancellationPersisted == (checkpoint.state == .cancelled),
              (checkpoint.state == .waiting) == (checkpoint.pendingAuthorizationTicketID != nil) else {
            throw BoneAgentWorkflowStepError.invalidState
        }
    }

    private func ensureMutableRunning() throws {
        try ensureNotTerminal()
        guard checkpoint.state == .running else { throw BoneAgentWorkflowStepError.invalidState }
    }

    private func ensureNotTerminal() throws {
        guard checkpoint.terminalState == nil else { throw BoneAgentWorkflowStepError.terminalState }
    }

    private func copy(
        state: BoneWorkflowStepState? = nil,
        inferenceResponseCount: Int? = nil,
        toolResultCount: Int? = nil,
        pendingAuthorizationTicketID: BoneAuthorizationTicketID? = nil,
        clearAuthorizationTicket: Bool = false,
        cancellationPersisted: Bool? = nil,
        terminalState: BoneAgentWorkflowStepTerminalState? = nil
    ) -> BoneAgentWorkflowStepCheckpoint {
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
