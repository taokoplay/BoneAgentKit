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
    /// 指向 Host-owned Agent 执行快照的引用。正文不进入普通 Workflow checkpoint。
    public let executionSnapshotReference: BoneWorkflowAgentExecutionSnapshotReference?

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
        leaseGeneration: UInt64 = 0,
        executionSnapshotReference: BoneWorkflowAgentExecutionSnapshotReference? = nil
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
        self.executionSnapshotReference = executionSnapshotReference
    }
}

public struct BoneWorkflowAgentStepCheckpointStore: Sendable {
    /// 统一处理步骤 checkpoint 与可选执行快照的 Host 提交闭包。
    private let commitWithSnapshotClosure: @Sendable (
        BoneWorkflowAgentStepCheckpoint,
        BoneWorkflowAgentExecutionSnapshot?,
        UInt64,
        UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint

    /// 兼容已有 Host Store 的三参数提交入口。
    public init(_ commit: @escaping @Sendable (
        BoneWorkflowAgentStepCheckpoint,
        UInt64,
        UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint) {
        commitWithSnapshotClosure = { checkpoint, snapshot, revision, lease in
            guard snapshot == nil else {
                throw BoneWorkflowAgentStepError.executionSnapshotCommitUnavailable
            }
            return try await commit(checkpoint, revision, lease)
        }
    }

    /// 支持将执行快照和 Step checkpoint 交给同一个 Host 提交边界。
    public init(commitWithSnapshot: @escaping @Sendable (
        BoneWorkflowAgentStepCheckpoint,
        BoneWorkflowAgentExecutionSnapshot?,
        UInt64,
        UInt64
    ) async throws -> BoneWorkflowAgentStepCheckpoint) {
        commitWithSnapshotClosure = commitWithSnapshot
    }

    /// 提交步骤 checkpoint，并在需要时把完整执行快照交给同一 Host 边界。
    /// - Parameters:
    ///   - checkpoint: 待提交的下一版步骤 checkpoint。
    ///   - expectedRevision: Host 当前已知的 checkpoint revision。
    ///   - leaseGeneration: 发起提交的执行代次。
    ///   - executionSnapshot: 与 checkpoint 引用匹配的可选执行快照正文。
    /// - Returns: Host 确认提交后的步骤 checkpoint。
    /// - Throws: Host Store 拒绝、CAS 冲突、lease 失效或快照能力不可用时抛出错误。
    public func commit(
        _ checkpoint: BoneWorkflowAgentStepCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64,
        executionSnapshot: BoneWorkflowAgentExecutionSnapshot? = nil
    ) async throws -> BoneWorkflowAgentStepCheckpoint {
        try await commitWithSnapshotClosure(checkpoint, executionSnapshot, expectedRevision, leaseGeneration)
    }
}

public enum BoneWorkflowAgentStepEventKind: String, Codable, Equatable, Sendable {
    case inferenceCheckpointed
    case toolResultCheckpointed
    case executionSnapshotCheckpointed
    case waitingForAuthorization
    case resumed
    case paused
    case recoveryRequired
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
    case executionSnapshotMismatch
    case executionSnapshotCommitUnavailable
}

public actor BoneWorkflowAgentStepController {
    public private(set) var checkpoint: BoneWorkflowAgentStepCheckpoint
    private let persistence: BoneWorkflowAgentStepCheckpointStore
    private let eventSink: BoneWorkflowAgentStepEventSink
    /// 一旦提交尝试未获有效回执，本实例不能盲写后继状态；Host 必须重读后重建 controller。
    private(set) var hasUnconfirmedCommit = false

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

    /// 将 Host 保存的 Agent 执行快照引用绑定到下一版 Step checkpoint。
    /// 引用正文由 Host 管理，方法只验证身份、lease 和 revision，避免敏感会话内容进入普通 checkpoint。
    public func bindExecutionSnapshot(_ reference: BoneWorkflowAgentExecutionSnapshotReference) async throws {
        try ensureMutableRunning()
        guard reference.runID == checkpoint.runID,
              reference.stepID == checkpoint.stepID,
              reference.attemptID == checkpoint.attemptID,
              reference.checkpointRevision == checkpoint.persistenceRevision + 1,
              reference.leaseGeneration == checkpoint.leaseGeneration else {
            throw BoneWorkflowAgentStepError.executionSnapshotMismatch
        }
        try await commit(copy(executionSnapshotReference: reference), event: .executionSnapshotCheckpointed)
    }

    /// 将完整 Host-owned 执行快照与下一版 Step checkpoint 交给同一个提交边界。
    /// Host Store 必须在返回前确认两者已经按同一 revision 和 lease 成功写入。
    public func bindExecutionSnapshot(_ snapshot: BoneWorkflowAgentExecutionSnapshot) async throws {
        try ensureMutableRunning()
        try validateSnapshotReference(snapshot.reference, nextRevision: checkpoint.persistenceRevision + 1)
        try await commit(
            copy(executionSnapshotReference: snapshot.reference),
            snapshot: snapshot,
            event: .executionSnapshotCheckpointed
        )
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

    /// 外部副作用或控制面提交结果未知；保留无业务终态的 checkpoint 等待 Host 调和。
    public func requireRecovery() async throws {
        try ensureNotTerminal()
        try await commit(copy(state: .commitUncertain, clearAuthorizationTicket: true), event: .recoveryRequired)
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
            do { try await self.receive(progress) }
            catch {
                if await self.hasUnconfirmedCommit {
                    // 在途 progress 可能输给已确认的取消；这不是新的副作用未知。
                    if await self.checkpoint.state == .cancelled { throw CancellationError() }
                    throw BoneAgentError.toolRecoveryRequired
                }
                throw error
            }
        }
    }

    private func commit(
        _ next: BoneWorkflowAgentStepCheckpoint,
        snapshot: BoneWorkflowAgentExecutionSnapshot? = nil,
        event: BoneWorkflowAgentStepEventKind
    ) async throws {
        // Reject illegal transitions before touching the Host store. Same-state updates
        // are running progress only; explicit recovery transitions are in the public table.
        if checkpoint.state != next.state {
            guard (try? checkpoint.state.transitioned(to: next.state)) != nil else {
                throw BoneWorkflowAgentStepError.invalidState
            }
        }
        guard next.persistenceRevision < UInt64.max else { throw BoneWorkflowAgentStepError.invalidState }
        try Self.validate(next, referenceRevision: next.persistenceRevision + 1)
        if let snapshot {
            guard snapshot.reference == next.executionSnapshotReference else {
                throw BoneWorkflowAgentStepError.executionSnapshotMismatch
            }
        }
        let stored: BoneWorkflowAgentStepCheckpoint
        do {
            stored = try await persistence.commit(
                next,
                expectedRevision: checkpoint.persistenceRevision,
                leaseGeneration: checkpoint.leaseGeneration,
                executionSnapshot: snapshot
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
                  stored.executionSnapshotReference == next.executionSnapshotReference,
                  stored.leaseGeneration == next.leaseGeneration,
                  stored.persistenceRevision == next.persistenceRevision + 1 else {
                throw BoneWorkflowAgentStepError.invalidState
            }
        } catch let error as BoneWorkflowAgentStepError where error == .executionSnapshotCommitUnavailable {
            // 旧版三参数 Store 在真正写入前明确拒绝快照，不存在外部提交结果未知。
            throw error
        } catch {
            hasUnconfirmedCommit = true
            throw error
        }
        checkpoint = stored
        await eventSink.receive(.init(kind: event))
    }

    private func validateSnapshotReference(
        _ reference: BoneWorkflowAgentExecutionSnapshotReference,
        nextRevision: UInt64
    ) throws {
        guard reference.runID == checkpoint.runID,
              reference.stepID == checkpoint.stepID,
              reference.attemptID == checkpoint.attemptID,
              reference.checkpointRevision == nextRevision,
              reference.leaseGeneration == checkpoint.leaseGeneration else {
            throw BoneWorkflowAgentStepError.executionSnapshotMismatch
        }
    }

    private static func validate(_ checkpoint: BoneWorkflowAgentStepCheckpoint, referenceRevision: UInt64? = nil) throws {
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
        if let reference = checkpoint.executionSnapshotReference {
            guard reference.runID == checkpoint.runID,
                  reference.stepID == checkpoint.stepID,
                  reference.attemptID == checkpoint.attemptID,
                  reference.checkpointRevision == (referenceRevision ?? checkpoint.persistenceRevision),
                  reference.leaseGeneration == checkpoint.leaseGeneration else {
                throw BoneWorkflowAgentStepError.executionSnapshotMismatch
            }
        }
    }

    private func ensureMutableRunning() throws {
        try ensureNotTerminal()
        guard checkpoint.state == .running else { throw BoneWorkflowAgentStepError.invalidState }
    }

    private func ensureNotTerminal() throws {
        guard checkpoint.terminalState == nil,
              checkpoint.state != .commitUncertain, checkpoint.state != .skipped else {
            throw BoneWorkflowAgentStepError.terminalState
        }
        guard !hasUnconfirmedCommit else { throw BoneWorkflowAgentStepError.invalidState }
    }

    private func copy(
        state: BoneWorkflowStepState? = nil,
        inferenceResponseCount: Int? = nil,
        toolResultCount: Int? = nil,
        pendingAuthorizationTicketID: BoneAuthorizationTicketID? = nil,
        clearAuthorizationTicket: Bool = false,
        cancellationPersisted: Bool? = nil,
        terminalState: BoneWorkflowAgentStepTerminalState? = nil,
        executionSnapshotReference: BoneWorkflowAgentExecutionSnapshotReference? = nil
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
            leaseGeneration: checkpoint.leaseGeneration,
            executionSnapshotReference: executionSnapshotReference
        )
    }
}
