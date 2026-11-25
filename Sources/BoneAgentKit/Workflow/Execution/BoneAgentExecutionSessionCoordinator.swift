import Foundation

/// 长期 Agent Session 的静态身份和持久化绑定。
///
/// 这些摘要由 Host 根据实际运行配置计算并持久化。协调器只校验它们是否保持一致，
/// 不从凭据、网络地址或私有 Prompt 正文推导摘要。
public struct BoneAgentExecutionSessionBinding: Codable, Equatable, Sendable {
    public let workflowIdentity: String
    public let workflowRevision: UInt64
    public let configurationDigest: String
    public let toolCatalogDigest: String
    public let promptProfileDigest: String?

    /// 创建长期 Session 的运行绑定。
    /// - Parameters:
    ///   - workflowIdentity: Workflow 的稳定身份。
    ///   - workflowRevision: Workflow 的不可变版本。
    ///   - configurationDigest: Agent 和 Provider 配置的 SHA-256 摘要。
    ///   - toolCatalogDigest: 暴露给模型的 Tool Catalog SHA-256 摘要。
    ///   - promptProfileDigest: 已编译业务 Prompt Profile 的可选 SHA-256 摘要。
    /// - Throws: 任一字段不满足 Session 持久化合同约束时抛出错误。
    public init(
        workflowIdentity: String,
        workflowRevision: UInt64,
        configurationDigest: String,
        toolCatalogDigest: String,
        promptProfileDigest: String? = nil
    ) throws {
        guard (1...128).contains(workflowIdentity.utf8.count),
              workflowIdentity.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 95].contains($0)
              }),
              workflowRevision > 0,
              Self.validDigest(configurationDigest),
              Self.validDigest(toolCatalogDigest),
              promptProfileDigest.map(Self.validDigest) ?? true else {
            throw BoneAgentExecutionSessionCoordinatorError.invalidInput
        }
        self.workflowIdentity = workflowIdentity
        self.workflowRevision = workflowRevision
        self.configurationDigest = configurationDigest
        self.toolCatalogDigest = toolCatalogDigest
        self.promptProfileDigest = promptProfileDigest
    }

    /// 验证 Session 是否仍绑定到当前运行配置。
    /// - Parameter session: 待校验的长期 Session。
    /// - Throws: Session 身份或配置摘要发生漂移时抛出协调器错误。
    public func validate(_ session: BoneAgentExecutionSession) throws {
        guard session.workflowIdentity == workflowIdentity,
              session.workflowRevision == workflowRevision,
              session.configurationDigest == configurationDigest,
              session.toolCatalogDigest == toolCatalogDigest,
              session.promptProfileDigest == promptProfileDigest else {
            throw BoneAgentExecutionSessionCoordinatorError.configurationDrift
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}

/// 可恢复 Agent Session 的稳定错误。
///
/// 错误只携带 Host 可路由的固定类别，不包含 Prompt、Tool 参数、Provider 响应或凭据。
public enum BoneAgentExecutionSessionCoordinatorError: Error, Codable, Equatable, Sendable {
    case invalidInput
    case sessionNotRunnable
    case missingSnapshot
    case snapshotBindingMismatch
    case configurationDrift
    case providerContinuationInvalid
    case persistenceOutcomeUnknown
    case recoveryRequired
    case effectRecoveryUnavailable
    case revisionConflict
    case leaseConflict
    case persistenceCapabilityUnavailable
    case identityMismatch
}

/// Effect 恢复审查的稳定结果。
///
/// 结果只携带 Effect 身份、Planner 动作和当前 lease，不携带 Tool 参数、Receipt 正文或业务结果。
public struct BoneAgentEffectRecoveryDecision: Codable, Equatable, Sendable {
    public let effectID: BoneEffectID
    public let action: BoneWorkflowRecoveryAction
    public let leaseGeneration: UInt64

    /// 创建一次 Effect 恢复审查结果。
    /// - Parameters:
    ///   - effectID: 待审查的副作用身份。
    ///   - action: Recovery Planner 基于持久化事实给出的动作。
    ///   - leaseGeneration: 审查时读取的当前 Session lease generation。
    public init(
        effectID: BoneEffectID,
        action: BoneWorkflowRecoveryAction,
        leaseGeneration: UInt64
    ) {
        self.effectID = effectID
        self.action = action
        self.leaseGeneration = leaseGeneration
    }
}

/// BoneAgent、Session Store 和私有快照 Store 的恢复协调器。
///
/// 每次成功执行只发布一个完整 Conversation 快照。快照与 Session 的新引用必须通过
/// Session Store 的联合提交入口保存，避免在模型调用已经成功后留下无法判断的半提交状态。
public actor BoneAgentExecutionSessionCoordinator {
    private let agent: BoneAgent
    private let sessionStore: any BoneAgentExecutionSessionStore
    private let snapshotStore: any BoneWorkflowAgentExecutionSnapshotStore
    private let binding: BoneAgentExecutionSessionBinding

    /// 创建恢复协调器。
    /// - Parameters:
    ///   - agent: 提供模型调用、Tool 校验和 Conversation 恢复的 Agent。
    ///   - sessionStore: 提供 Session CAS、lease 和 Session/快照联合提交的 Host Store。
    ///   - snapshotStore: 提供按完整引用读取私有 Conversation 快照的 Host Store。
    ///   - binding: 当前 Host 运行配置的稳定绑定。
    public init(
        agent: BoneAgent,
        sessionStore: any BoneAgentExecutionSessionStore,
        snapshotStore: any BoneWorkflowAgentExecutionSnapshotStore,
        binding: BoneAgentExecutionSessionBinding
    ) {
        self.agent = agent
        self.sessionStore = sessionStore
        self.snapshotStore = snapshotStore
        self.binding = binding
    }

    /// 创建并持久化一个可恢复的长期 Session。
    /// - Parameters:
    ///   - session: 尚未保存或与 Store 中完全相同的初始 Session。
    ///   - conversation: 已按当前 Agent 配置创建的空 Conversation。
    ///   - stepID: 当前 Agent Step 的稳定身份。
    ///   - attemptID: 当前执行 Attempt 的稳定身份。
    ///   - effectLedgerRevision: 当前副作用账本 revision。
    /// - Returns: 已取得首个 lease、已绑定初始快照的 Session。
    /// - Throws: Session 身份、Conversation 绑定或联合持久化不满足合同时抛出错误。
    public func start(
        session: BoneAgentExecutionSession,
        conversation: BoneAgentConversation,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        effectLedgerRevision: UInt64 = 0
    ) async throws -> BoneAgentExecutionSession {
        try validate(session: session)
        guard session.state == .active, session.snapshotReference == nil else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        try await validateConversation(conversation, session: session, expectedRevision: 0)
        let opened = try await sessionStore.open(session)
        guard opened == session else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        let leased = try await sessionStore.acquireLease(sessionID: session.sessionID, expectedRevision: opened.revision)
        let snapshot = try await makeSnapshot(
            conversation: conversation,
            runID: leased.runID,
            stepID: stepID,
            attemptID: attemptID,
            effectLedgerRevision: effectLedgerRevision,
            checkpointRevision: 1,
            leaseGeneration: leased.leaseGeneration
        )
        let bound = try leased.binding(snapshot: snapshot.reference)
        return try await commit(
            bound,
            snapshot: snapshot,
            expectedRevision: leased.revision,
            leaseGeneration: leased.leaseGeneration
        )
    }

    /// 恢复一个已持久化 Conversation，并执行一轮新的用户输入。
    /// - Parameters:
    ///   - sessionID: 要恢复的长期 Session 标识。
    ///   - userMessage: 本轮发送给模型的用户消息。
    ///   - snapshotContext: 可选的模型上下文快照信息。
    /// - Returns: 模型成功完成后的本轮 Agent 结果。
    /// - Throws: 快照、配置、lease 或模型执行无法安全恢复时抛出协调器错误。
    public func run(
        sessionID: String,
        userMessage: String,
        snapshotContext: BoneAgentModelSnapshotContext? = nil
    ) async throws -> BoneAgentRunResult {
        let loaded = try await sessionStore.load(sessionID: sessionID)
        try loaded.validate()
        do {
            try binding.validate(loaded)
        } catch let error as BoneAgentExecutionSessionCoordinatorError where error == .configurationDrift {
            let leased = try await acquireLease(loaded)
            try await enterRecovery(leased, reason: .configurationDrift)
            throw error
        }
        guard loaded.state == .active || loaded.state == .paused else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        guard !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              userMessage.utf8.count <= BoneAgentConversation.maximumUserMessageBytes else {
            throw BoneAgentExecutionSessionCoordinatorError.invalidInput
        }
        guard let previousReference = loaded.snapshotReference else {
            let leased = try await acquireLease(loaded)
            try await enterRecovery(leased, reason: .missingSnapshot)
            throw BoneAgentExecutionSessionCoordinatorError.missingSnapshot
        }

        let previousSnapshot: BoneWorkflowAgentExecutionSnapshot
        do {
            previousSnapshot = try await snapshotStore.load(reference: previousReference)
        } catch let error as BoneWorkflowAgentExecutionSnapshotError where error == .missingSnapshot {
            let leased = try await acquireLease(loaded)
            try await enterRecovery(leased, reason: .missingSnapshot)
            throw BoneAgentExecutionSessionCoordinatorError.missingSnapshot
        } catch {
            throw error
        }
        guard previousSnapshot.reference == previousReference,
              previousReference.runID == loaded.runID else {
            let leased = try await acquireLease(loaded)
            try await enterRecovery(leased, reason: .snapshotBindingMismatch)
            throw BoneAgentExecutionSessionCoordinatorError.snapshotBindingMismatch
        }

        let leased = try await acquireLease(loaded)
        let conversation: BoneAgentConversation
        do {
            conversation = try await agent.restoreConversation(
                privateState: previousSnapshot.privateConversationState,
                modelID: leased.modelID,
                bindingID: leased.bindingID,
                expectedID: leased.conversationID,
                expectedRevision: previousReference.conversationRevision
            )
        } catch let error as BoneAgentConversationError {
            let reason: BoneAgentExecutionRecoveryReason = error == .toolsChanged || error == .bindingMismatch
                ? .configurationDrift
                : .providerContinuationInvalid
            try await enterRecovery(leased, reason: reason)
            throw reason == .configurationDrift
                ? BoneAgentExecutionSessionCoordinatorError.configurationDrift
                : BoneAgentExecutionSessionCoordinatorError.providerContinuationInvalid
        }

        let running = try transitionToRunning(leased)
        let runningSession = try await commit(running, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
        let executionScope = try BoneWorkflowExecutionScope(
            sessionID: runningSession.sessionID,
            runID: runningSession.runID,
            stepID: previousReference.stepID,
            attemptID: previousReference.attemptID,
            leaseGeneration: runningSession.leaseGeneration
        )
        let result: BoneAgentRunResult
        do {
            result = try await BoneWorkflowExecutionScopeContext.$current.withValue(executionScope) {
                try await conversation.send(userMessage, snapshotContext: snapshotContext)
            }
        } catch let error as BoneAgentConversationError where error == .invalidUserMessage {
            let active = try runningSession.transitioned(to: .active)
            _ = try await commit(active, expectedRevision: runningSession.revision, leaseGeneration: runningSession.leaseGeneration)
            throw BoneAgentExecutionSessionCoordinatorError.invalidInput
        } catch let error as BoneAgentError where error == .runAlreadyInProgress {
            let active = try runningSession.transitioned(to: .active)
            _ = try await commit(active, expectedRevision: runningSession.revision, leaseGeneration: runningSession.leaseGeneration)
            throw error
        } catch let error as BoneAgentError {
            let reason: BoneAgentExecutionRecoveryReason = {
                switch error {
                case .toolOutcomeUnknown, .toolRecoveryRequired:
                    return .toolOutcomeUnknown
                default:
                    return .providerContinuationInvalid
                }
            }()
            try await enterRecovery(runningSession, reason: reason)
            throw error
        } catch {
            try await enterRecovery(runningSession, reason: .providerContinuationInvalid)
            throw BoneAgentExecutionSessionCoordinatorError.providerContinuationInvalid
        }

        let snapshot = try await makeSnapshot(
            conversation: conversation,
            runID: runningSession.runID,
            stepID: previousReference.stepID,
            attemptID: previousReference.attemptID,
            effectLedgerRevision: previousReference.effectLedgerRevision,
            checkpointRevision: try increment(previousReference.checkpointRevision),
            leaseGeneration: runningSession.leaseGeneration
        )
        let sessionWithSnapshot = try runningSession.binding(snapshot: snapshot.reference)
        let committedWithSnapshot = try await commit(
            sessionWithSnapshot,
            snapshot: snapshot,
            expectedRevision: runningSession.revision,
            leaseGeneration: runningSession.leaseGeneration
        )
        let active = try committedWithSnapshot.transitioned(to: .active)
        _ = try await commit(active, expectedRevision: committedWithSnapshot.revision, leaseGeneration: committedWithSnapshot.leaseGeneration)
        return result
    }

    /// 将 Session 暂停并持久化，阻止后续新的 Agent Turn。
    /// - Parameter sessionID: 要暂停的 Session 标识。
    /// - Returns: 已确认进入 paused 状态的 Session。
    /// - Throws: Session 不存在、已终止、revision 冲突或 lease 失效时抛出错误。
    public func pause(sessionID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        let leased = try await acquireLease(session)
        let paused = try leased.transitioned(to: .paused)
        return try await commit(paused, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 记录等待用户输入的 Attention，并保持 Session 可恢复。
    /// - Parameters:
    ///   - sessionID: 要更新的 Session 标识。
    ///   - requestID: Host 生成的用户输入请求标识。
    /// - Returns: 已确认进入 waitingForUser 状态的 Session。
    /// - Throws: Session 不可运行、请求标识非法或持久化冲突时抛出错误。
    public func waitForUser(sessionID: String, requestID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else { throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable }
        let leased = try await acquireLease(session)
        let attention = try BoneAgentExecutionAttention(userInput: requestID)
        let waiting = try leased.transitioned(to: .waitingForUser, attention: attention)
        return try await commit(waiting, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 记录等待授权的 Attention，并保持 Session 可恢复。
    /// - Parameters:
    ///   - sessionID: 要更新的 Session 标识。
    ///   - ticketID: 待 Host 消费的一次性授权票据。
    /// - Returns: 已确认进入 waitingForAuthorization 状态的 Session。
    /// - Throws: Session 不可运行、票据非法或持久化冲突时抛出错误。
    public func waitForAuthorization(
        sessionID: String,
        ticketID: BoneAuthorizationTicketID
    ) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else { throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable }
        let leased = try await acquireLease(session)
        let waiting = try leased.transitioned(
            to: .waitingForAuthorization,
            attention: .authorization(ticketID: ticketID)
        )
        return try await commit(waiting, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 记录等待人工审核的 Attention，并保持 Session 可恢复。
    /// - Parameters:
    ///   - sessionID: 要更新的 Session 标识。
    ///   - reviewID: Host 生成的审核记录标识。
    /// - Returns: 已确认进入 waitingForReview 状态的 Session。
    /// - Throws: Session 不可运行、审核标识非法或持久化冲突时抛出错误。
    public func waitForReview(sessionID: String, reviewID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else { throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable }
        let leased = try await acquireLease(session)
        let waiting = try leased.transitioned(
            to: .waitingForReview,
            attention: try BoneAgentExecutionAttention(review: reviewID)
        )
        return try await commit(waiting, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 记录等待外部事件的 Attention，并保持 Session 可恢复。
    /// - Parameters:
    ///   - sessionID: 要更新的 Session 标识。
    ///   - eventID: Host 生成的外部事件标识。
    /// - Returns: 已确认进入 waitingForExternalEvent 状态的 Session。
    /// - Throws: Session 不可运行、事件标识非法或持久化冲突时抛出错误。
    public func waitForExternalEvent(sessionID: String, eventID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else { throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable }
        let leased = try await acquireLease(session)
        let waiting = try leased.transitioned(
            to: .waitingForExternalEvent,
            attention: try BoneAgentExecutionAttention(externalEvent: eventID)
        )
        return try await commit(waiting, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 在 Host 已处理 Attention 后恢复执行状态。
    /// - Parameter sessionID: 要恢复的 Session 标识。
    /// - Returns: 已确认进入 active 状态的 Session。
    /// - Throws: Session 不在等待状态、租约冲突或持久化失败时抛出错误。
    public func resume(sessionID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .paused || session.state == .waitingForUser || session.state == .waitingForAuthorization ||
              session.state == .waitingForReview || session.state == .waitingForExternalEvent else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        let leased = try await acquireLease(session)
        let active = try leased.transitioned(to: .active)
        return try await commit(active, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 显式取消 Session，供 Host 在业务取消已持久化后调用。
    /// - Parameter sessionID: 要取消的 Session 标识。
    /// - Returns: 已确认进入 cancelled 状态的 Session。
    /// - Throws: Session 已终止、lease 冲突或持久化失败时抛出错误。
    public func cancel(sessionID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state != .recoveryRequired else {
            throw BoneAgentExecutionSessionCoordinatorError.recoveryRequired
        }
        let leased = try await acquireLease(session)
        let cancelled = try leased.transitioned(to: .cancelled)
        return try await commit(cancelled, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 显式标记 Session 完成，供 Workflow/Host 在业务结果已提交后调用。
    /// - Parameter sessionID: 已完成业务提交的 Session 标识。
    /// - Returns: 已确认进入 completed 状态的 Session。
    /// - Throws: Session 不在 active 状态或持久化冲突时抛出错误。
    public func complete(sessionID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state == .active else { throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable }
        let leased = try await acquireLease(session)
        let completed = try leased.transitioned(to: .completed)
        return try await commit(completed, expectedRevision: leased.revision, leaseGeneration: leased.leaseGeneration)
    }

    /// 读取当前 Session，供 Host 展示状态和 Attention。
    /// - Parameter sessionID: 要读取的 Session 标识。
    /// - Returns: Store 中最新且通过绑定校验的 Session。
    /// - Throws: Session 不存在或当前配置已漂移时抛出错误。
    public func load(sessionID: String) async throws -> BoneAgentExecutionSession {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        return session
    }

    /// 审查一个已持久化 Effect 的恢复动作，并在未知结果时锁定 Session 恢复态。
    ///
    /// 该方法不会执行 Tool。`execute` 只表示 Intent 已持久化且可以由 Host 使用同一
    /// Effect identity 进入执行管线，`commitReceipt` 表示已确认的 Receipt 可以提交，
    /// `recoveryRequired` 表示必须由 Host 对账或人工决定后才能继续。
    /// - Parameters:
    ///   - sessionID: Effect 所属的 Agent Session 标识。
    ///   - effectID: 待恢复的 Effect 身份。
    ///   - pipeline: 使用同一 Host Effect Store 的恢复管线。
    /// - Returns: 包含 Planner 动作和当前 lease generation 的稳定恢复结果。
    /// - Throws: Session 绑定、lease、Effect Store 或持久化提交无法确认时抛出错误。
    public func recoverEffect(
        sessionID: String,
        effectID: BoneEffectID,
        pipeline: BoneWorkflowToolExecutionPipeline
    ) async throws -> BoneAgentEffectRecoveryDecision {
        let session = try await sessionStore.load(sessionID: sessionID)
        try validate(session: session)
        guard session.state != .completed, session.state != .cancelled else {
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
        guard let reference = session.snapshotReference else {
            throw BoneAgentExecutionSessionCoordinatorError.identityMismatch
        }
        let recoveryScope = BoneWorkflowEffectRecoveryScope(
            sessionID: session.sessionID,
            runID: session.runID,
            stepID: reference.stepID,
            attemptID: reference.attemptID
        )

        let action: BoneWorkflowRecoveryAction
        do {
            action = try await pipeline.recoveryAction(
                effectID: effectID,
                currentLeaseGeneration: session.leaseGeneration,
                expectedScope: recoveryScope
            )
        } catch let error as BoneWorkflowToolExecutionError {
            switch error {
            case .pipelineUnavailable:
                throw BoneAgentExecutionSessionCoordinatorError.effectRecoveryUnavailable
            case .identityMismatch:
                throw BoneAgentExecutionSessionCoordinatorError.identityMismatch
            case .recoveryRequired, .outcomeUnknown:
                let leased = try await acquireLeaseIfNeeded(session)
                try await enterRecovery(leased, reason: .effectReceiptUnknown)
                throw BoneAgentExecutionSessionCoordinatorError.recoveryRequired
            default:
                throw error
            }
        }

        let resolvedAction: BoneWorkflowRecoveryAction
        if case .commitReceipt = action {
            do {
                resolvedAction = try await pipeline.commitRecoveredReceipt(
                    effectID: effectID,
                    currentLeaseGeneration: session.leaseGeneration,
                    expectedScope: recoveryScope
                )
            } catch {
                let leased = try await acquireLeaseIfNeeded(session)
                try await enterRecovery(leased, reason: .persistenceOutcomeUnknown)
                throw BoneAgentExecutionSessionCoordinatorError.persistenceOutcomeUnknown
            }
        } else {
            resolvedAction = action
        }
        if case let .recoveryRequired(reason) = resolvedAction {
            let leased = try await acquireLeaseIfNeeded(session)
            try await enterRecovery(leased, reason: mapRecoveryReason(reason))
        }
        return BoneAgentEffectRecoveryDecision(
            effectID: effectID,
            action: resolvedAction,
            leaseGeneration: session.leaseGeneration
        )
    }

    private func validate(session: BoneAgentExecutionSession) throws {
        try session.validate()
        try binding.validate(session)
    }

    private func validateConversation(
        _ conversation: BoneAgentConversation,
        session: BoneAgentExecutionSession,
        expectedRevision: UInt64
    ) async throws {
        guard await conversation.id == session.conversationID,
              await conversation.modelID == session.modelID,
              await conversation.bindingID == session.bindingID,
              await conversation.revision == expectedRevision else {
            throw BoneAgentExecutionSessionCoordinatorError.snapshotBindingMismatch
        }
    }

    /// 取得下一代 lease，并把 Host Store 的确定性冲突映射为稳定的 Coordinator 错误。
    /// - Parameter session: 当前已读取并通过绑定校验的 Session。
    /// - Returns: 已取得下一代 lease 的 Session。
    /// - Throws: revision 或 lease 冲突、终态拒绝或持久化结果未知时抛出协调器错误。
    private func acquireLease(_ session: BoneAgentExecutionSession) async throws -> BoneAgentExecutionSession {
        do {
            return try await sessionStore.acquireLease(sessionID: session.sessionID, expectedRevision: session.revision)
        } catch {
            throw mapStoreError(error)
        }
    }

    private func transitionToRunning(_ session: BoneAgentExecutionSession) throws -> BoneAgentExecutionSession {
        switch session.state {
        case .active, .paused:
            return try session.transitioned(to: .running)
        default:
            throw BoneAgentExecutionSessionCoordinatorError.sessionNotRunnable
        }
    }

    private func makeSnapshot(
        conversation: BoneAgentConversation,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        effectLedgerRevision: UInt64,
        checkpointRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowAgentExecutionSnapshot {
        let data = try await conversation.exportPrivateState()
        let state = try BoneAgentConversationState.decode(data)
        let reference = try BoneWorkflowAgentExecutionSnapshotReference(
            referenceID: UUID().uuidString.lowercased(),
            schemaVersion: 1,
            runID: runID,
            stepID: stepID,
            attemptID: attemptID,
            conversationRevision: state.revision,
            contextRevision: state.contextRevision,
            effectLedgerRevision: effectLedgerRevision,
            checkpointRevision: checkpointRevision,
            leaseGeneration: leaseGeneration
        )
        return try BoneWorkflowAgentExecutionSnapshot(reference: reference, privateConversationState: data)
    }

    /// 提交 Session 或 Session/快照联合事务，并区分确定性拒绝与结果未知。
    /// - Parameters:
    ///   - session: 待提交的下一版 Session。
    ///   - snapshot: 可选的与 Session 引用绑定的私有快照。
    ///   - expectedRevision: 调用方读取到的旧 revision。
    ///   - leaseGeneration: 调用方持有的 lease generation。
    /// - Returns: Host 确认提交后的 Session。
    /// - Throws: 确定性 CAS、lease 或能力错误，或无法确认的持久化结果。
    private func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot? = nil,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentExecutionSession {
        do {
            return try await sessionStore.commit(
                session,
                snapshot: snapshot,
                expectedRevision: expectedRevision,
                leaseGeneration: leaseGeneration
            )
        } catch {
            throw mapStoreError(error)
        }
    }

    /// 将 Host Store 的已知错误保持为可路由的确定性错误，其余错误才标记为结果未知。
    /// - Parameter error: Host Store 抛出的原始错误。
    /// - Returns: Coordinator 对下游暴露的稳定错误。
    private func mapStoreError(_ error: Error) -> BoneAgentExecutionSessionCoordinatorError {
        guard let error = error as? BoneAgentExecutionSessionError else {
            return .persistenceOutcomeUnknown
        }
        switch error {
        case .revisionConflict:
            return .revisionConflict
        case .leaseConflict:
            return .leaseConflict
        case .persistenceCapabilityUnavailable:
            return .persistenceCapabilityUnavailable
        case .identityMismatch, .identityReused:
            return .identityMismatch
        case .terminalState, .invalidTransition, .attentionMismatch:
            return .sessionNotRunnable
        case .invalidInput, .unsupportedVersion, .counterOverflow:
            return .invalidInput
        case .missingSession:
            return .sessionNotRunnable
        }
    }

    private func enterRecovery(
        _ session: BoneAgentExecutionSession,
        reason: BoneAgentExecutionRecoveryReason
    ) async throws {
        guard session.state != .recoveryRequired else { return }
        let recovery = try session.transitioned(to: .recoveryRequired, attention: .recovery(reason: reason))
        _ = try await commit(recovery, expectedRevision: session.revision, leaseGeneration: session.leaseGeneration)
    }

    /// 只有仍可被接管的 Session 才获取新 lease，已经进入 recoveryRequired 的 Session 保留原事实。
    /// - Parameter session: 当前读取到的 Session。
    /// - Returns: 可用于写入恢复状态的 Session。
    /// - Throws: Session 已终止或 lease 接管冲突时抛出错误。
    private func acquireLeaseIfNeeded(_ session: BoneAgentExecutionSession) async throws -> BoneAgentExecutionSession {
        if session.state == .recoveryRequired {
            return session
        }
        return try await acquireLease(session)
    }

    /// 将 Effect Planner 的原因映射为 Agent Session 对 Host 暴露的恢复原因。
    /// - Parameter reason: Effect Recovery Planner 的固定原因。
    /// - Returns: Agent Session 控制面的恢复原因。
    private func mapRecoveryReason(_ reason: BoneWorkflowRecoveryReason) -> BoneAgentExecutionRecoveryReason {
        switch reason {
        case .outcomeUnknown:
            return .effectReceiptUnknown
        case .fencingConflict:
            return .leaseConflict
        case .receiptMismatch:
            return .effectReceiptUnknown
        }
    }

    private func increment(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw BoneAgentExecutionSessionCoordinatorError.invalidInput }
        return next
    }
}
