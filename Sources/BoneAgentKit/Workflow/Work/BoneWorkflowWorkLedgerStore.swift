import Foundation

/// Host 负责真实存储事务、唯一键(runID,unitID,page)以及与Run/预算的授权协调。
/// 每个命令与lease推进须在同一事务校验revision/generation并完整保存，不支持静默部分写入。
public protocol BoneWorkflowWorkLedgerStore: Sendable {
    /// 原子准备或等值读回；已存在时preparedUnits与当前generation必须匹配，不重置工作进度。
    func open(runID: BoneRunID, leaseGeneration: UInt64, units: [BoneWorkflowWorkLedger.Seed]) async throws -> BoneWorkflowWorkLedger
    func load(runID: BoneRunID) async throws -> BoneWorkflowWorkLedger
    func apply(runID: BoneRunID, expectedRevision: UInt64, leaseGeneration: UInt64,
               command: BoneWorkflowWorkLedger.Command) async throws -> BoneWorkflowWorkLedger
    /// Host已获得真实Run接管权后推进围栏；与RunStore不是自动跨库原子事务。
    func advanceLease(runID: BoneRunID, expectedRevision: UInt64, expectedGeneration: UInt64,
                      newGeneration: UInt64) async throws -> BoneWorkflowWorkLedger
}

/// 参考实现只证明内存原子性，不能替代Host数据库/进程崩溃验收。
public actor BoneInMemoryWorkflowWorkLedgerStore: BoneWorkflowWorkReconciliationStore {
    private var ledgers: [BoneRunID: BoneWorkflowWorkLedger] = [:]
    public init() {}
    public func open(runID: BoneRunID, leaseGeneration: UInt64, units: [BoneWorkflowWorkLedger.Seed]) throws -> BoneWorkflowWorkLedger {
        try Task.checkCancellation()
        if let current = ledgers[runID] {
            guard current.preparedUnits == units else { throw BoneWorkflowWorkLedgerError.planMismatch }
            guard current.leaseGeneration == leaseGeneration else { throw BoneWorkflowWorkLedgerError.leaseConflict }
            return current
        }
        let ledger = try BoneWorkflowWorkLedger(runID: runID, leaseGeneration: leaseGeneration, units: units)
        ledgers[runID] = ledger
        return ledger
    }
    public func load(runID: BoneRunID) throws -> BoneWorkflowWorkLedger {
        try Task.checkCancellation()
        guard let ledger = ledgers[runID] else { throw BoneWorkflowWorkLedgerError.missingLedger }
        return ledger
    }
    public func apply(runID: BoneRunID, expectedRevision: UInt64, leaseGeneration: UInt64,
                      command: BoneWorkflowWorkLedger.Command) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: runID)
        guard current.revision == expectedRevision else { throw BoneWorkflowWorkLedgerError.revisionConflict }
        let next = try current.applying(command, leaseGeneration: leaseGeneration)
        ledgers[runID] = next
        return next
    }
    public func reconcile(_ reconciliation: BoneWorkflowWorkLedger.Reconciliation) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: reconciliation.runID)
        let next = try current.reconciling(reconciliation)
        ledgers[reconciliation.runID] = next
        return next
    }
    public func advanceLease(runID: BoneRunID, expectedRevision: UInt64, expectedGeneration: UInt64,
                             newGeneration: UInt64) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: runID)
        guard current.revision == expectedRevision else { throw BoneWorkflowWorkLedgerError.revisionConflict }
        let next = try current.advancingLease(expectedGeneration: expectedGeneration, newGeneration: newGeneration)
        ledgers[runID] = next
        return next
    }
}
