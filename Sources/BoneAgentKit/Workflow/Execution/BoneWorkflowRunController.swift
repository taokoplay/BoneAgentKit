import Foundation

/// 通用 Run 控制面，不持有 Worker、业务授权或预算，不解释 checkpoint payload。
/// 每次命令读取持久事实并使用显式 revision；多步操作不是单一事务，不自动重试或回滚。
/// 写入抛错或回执异常时立即停止。Host 必须重读并调和，不得盲目重发原命令。
public struct BoneWorkflowRunController: Sendable {
    private let persistence: any BoneWorkflowPersistence

    public init(persistence: any BoneWorkflowPersistence) {
        self.persistence = persistence
    }

    /// 创建控制器的新 Run，generation 从 0 起步；底层 Store 仍支持其他初始 generation。
    /// 业务实体映射不属于此方法；需要原子绑定时由 Host 自己的创建事务处理。
    public func createRun(
        runID: BoneRunID,
        plan: BoneWorkflowPlan,
        checkpoint: BoneWorkflowCheckpoint
    ) async throws -> BoneWorkflowRunSnapshot {
        try Task.checkCancellation()
        guard checkpoint.revision == 0 else { throw BoneWorkflowFailure.revisionConflict }
        guard checkpoint.descriptor.workflowIdentity == plan.identity,
              checkpoint.descriptor.workflowRevision == plan.revision else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        let run = BoneWorkflowRunRecord(id: runID, plan: plan, state: .pending, revision: 0, leaseGeneration: 0)
        let saved = try await persistence.create(run: run, checkpoint: checkpoint)
        return try verified(saved, expected: .init(run: run.stored(revision: 1), checkpoint: checkpoint.stored(revision: 1)))
    }

    /// 仅为 pending Run 提交已准备好的 checkpoint，不提供 Run→业务实体映射或索引。
    public func bindPreparedExecution(
        runID: BoneRunID,
        expectedRevision: UInt64,
        checkpoint: BoneWorkflowCheckpoint
    ) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        guard current.run.state == .pending else { throw BoneWorkflowFailure.invalidStateTransition }
        guard checkpoint.revision == expectedRevision else { throw BoneWorkflowFailure.revisionConflict }
        guard checkpoint.descriptor.workflowIdentity == current.run.plan.identity,
              checkpoint.descriptor.workflowRevision == current.run.plan.revision else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        return try await commit(current, state: .pending, checkpoint: checkpoint)
    }

    /// 即使 pending Run 已有非零 generation，也先换 lease 再进入 running。
    public func beginExecution(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        guard current.run.state == .pending else { throw BoneWorkflowFailure.invalidStateTransition }
        let leased = try await acquire(current)
        return try await commit(leased, state: .running)
    }

    /// running → pausing → 换 lease → paused；从 pausing 继续须使用重读后的 revision。
    /// paused 表示持久化控制面已停止推进，并非外部 Worker/Effect 已停止的证明。
    public func pauseExecution(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        let pausing: BoneWorkflowRunSnapshot
        switch current.run.state {
        case .running: pausing = try await commit(current, state: .pausing)
        case .pausing: pausing = current
        default: throw BoneWorkflowFailure.invalidStateTransition
        }
        let leased = try await acquire(pausing)
        return try await commit(leased, state: .paused)
    }

    /// 必须先换 lease；不能复用暂停前的 worker generation。
    public func resumePausedExecution(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        guard current.run.state == .paused else { throw BoneWorkflowFailure.invalidStateTransition }
        let leased = try await acquire(current)
        return try await commit(leased, state: .running)
    }

    /// 仅接管非终态 Run，不启动执行，不改变状态、冻结 Plan 或 checkpoint 中的额度/截止。
    /// recoveryRequired 沿现有状态机不可复活，必须由 Host 另行调和。
    public func recover(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        guard !isTerminal(current.run.state) else { throw BoneWorkflowFailure.invalidStateTransition }
        return try await acquire(current)
    }

    /// 只持久化 cancelling 意图；返回不代表 Worker 已停止，不直接提交 cancelled。
    /// 已 cancelling 时返回同一快照；终态拒绝，不触发业务取消闭包。
    public func requestCancellation(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let current = try await load(runID, expectedRevision: expectedRevision)
        guard !isTerminal(current.run.state) else { throw BoneWorkflowFailure.invalidStateTransition }
        if current.run.state == .cancelling { return current }
        return try await commit(current, state: .cancelling)
    }

    /// 只能在取消意图已落盘后请求对应 generation 的 Worker 停止，不写终态。
    /// Host 闭包必须按 snapshot 的身份/generation 定位 Worker；无 Worker 或闭包返回
    /// 都不证明 Effect 已收口。检查与外部闭包不是跨系统原子操作，Host 仍须执行 fencing。
    public func stopRequestedExecution(
        runID: BoneRunID,
        expectedRevision: UInt64,
        leaseGeneration: UInt64,
        stopWorker: @Sendable (BoneWorkflowRunSnapshot) async throws -> Void
    ) async throws {
        let current = try await load(runID, expectedRevision: expectedRevision, generation: leaseGeneration)
        guard current.run.state == .cancelling || current.run.state == .cancelled else {
            throw BoneWorkflowFailure.invalidStateTransition
        }
        try Task.checkCancellation()
        try await stopWorker(current)
    }

    /// Host 提供已对账的通用终态；此方法不把“无 Worker”或业务任务结束当作安全证据。
    /// 同终态且 revision/generation 匹配时只读返回，其他情况仍遵守状态迁移表。
    public func reconcileTerminal(
        runID: BoneRunID,
        state: BoneWorkflowRunState,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowRunSnapshot {
        guard isTerminal(state) else { throw BoneWorkflowFailure.invalidStateTransition }
        let current = try await load(runID, expectedRevision: expectedRevision, generation: leaseGeneration)
        if current.run.state == state { return current }
        return try await commit(current, state: state)
    }

    private func load(_ runID: BoneRunID, expectedRevision: UInt64, generation: UInt64? = nil) async throws -> BoneWorkflowRunSnapshot {
        try Task.checkCancellation()
        let current = try await persistence.load(runID: runID)
        guard current.run.id == runID,
              current.run.revision > 0,
              current.run.revision == current.checkpoint.revision,
              current.checkpoint.descriptor.workflowIdentity == current.run.plan.identity,
              current.checkpoint.descriptor.workflowRevision == current.run.plan.revision else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        guard current.run.revision == expectedRevision else { throw BoneWorkflowFailure.revisionConflict }
        if let generation, current.run.leaseGeneration != generation { throw BoneWorkflowFailure.leaseConflict }
        return current
    }

    private func acquire(_ current: BoneWorkflowRunSnapshot) async throws -> BoneWorkflowRunSnapshot {
        try Task.checkCancellation()
        let revision = try increment(current.run.revision)
        let generation = try increment(current.run.leaseGeneration)
        let saved = try await persistence.acquireLease(runID: current.run.id, expectedRevision: current.run.revision)
        return try verified(saved, expected: .init(run: current.run.stored(revision: revision, leaseGeneration: generation),
                                                  checkpoint: current.checkpoint.stored(revision: revision)))
    }

    private func commit(
        _ current: BoneWorkflowRunSnapshot,
        state: BoneWorkflowRunState,
        checkpoint: BoneWorkflowCheckpoint? = nil
    ) async throws -> BoneWorkflowRunSnapshot {
        try Task.checkCancellation()
        let nextState = state == current.run.state ? state : try current.run.state.transitioned(to: state)
        let revision = try increment(current.run.revision)
        let run = BoneWorkflowRunRecord(id: current.run.id, plan: current.run.plan, state: nextState,
            revision: current.run.revision, leaseGeneration: current.run.leaseGeneration)
        let payload = checkpoint ?? current.checkpoint
        let saved = try await persistence.commit(run: run, checkpoint: payload,
            expectedRevision: current.run.revision, leaseGeneration: current.run.leaseGeneration)
        return try verified(saved, expected: .init(run: run.stored(revision: revision), checkpoint: payload.stored(revision: revision)))
    }

    private func verified(_ saved: BoneWorkflowRunSnapshot, expected: BoneWorkflowRunSnapshot) throws -> BoneWorkflowRunSnapshot {
        guard saved == expected else { throw BoneWorkflowFailure.corruptedCheckpoint }
        return saved
    }

    private func increment(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowFailure.revisionConflict }
        return next
    }

    private func isTerminal(_ state: BoneWorkflowRunState) -> Bool {
        switch state {
        case .cancelled, .failed, .completed, .recoveryRequired: return true
        default: return false
        }
    }
}
