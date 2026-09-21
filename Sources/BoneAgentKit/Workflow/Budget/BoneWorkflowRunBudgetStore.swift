import Foundation

/// Host 持久化的 Run 预算边界。open/load/reserve 必须共享同一授权 scope，存储由 Host 实现。
public protocol BoneWorkflowRunBudgetStore: Sendable {
    /// 原子创建或等值读取。存在行必须逐字段校验 policy（包括版本标签），不重置计数/起止。
    /// now 只用于首次创建；旧行的当前时钟在 reserve 判定。更换版本标签不授权修改旧 Run。
    func open(runID: BoneRunID, policy: BoneWorkflowRunBudget.Policy, now: BoneWorkflowRunBudget.Clock) async throws -> BoneWorkflowRunBudget
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunBudget
    /// 在同一事务内读取 expectedRevision、计算 reserving、完整保存，然后返回对应回执。
    /// 业务拒绝也是已持久化的尝试，返回 rejected 而非 throw；I/O/CAS/取消异常不伪造回执。
    /// CAS 冲突不消费额度；成功后不退款。提交结果未知只重读，不用新 revision 盲目重试。
    func reserve(runID: BoneRunID, expectedRevision: UInt64, phase: BoneWorkflowRunBudget.Phase,
                 now: BoneWorkflowRunBudget.Clock) async throws -> BoneWorkflowRunBudget.Reservation
}

/// 原子语义参考；不是磁盘持久化、跨进程或真实数据库事务证明。
public actor BoneInMemoryWorkflowRunBudgetStore: BoneWorkflowRunBudgetStore {
    private var budgets: [BoneRunID: BoneWorkflowRunBudget] = [:]
    public init() {}

    public func open(runID: BoneRunID, policy: BoneWorkflowRunBudget.Policy, now: BoneWorkflowRunBudget.Clock) throws -> BoneWorkflowRunBudget {
        try Task.checkCancellation()
        if let current = budgets[runID] {
            guard current.policy == policy else { throw BoneWorkflowRunBudgetError.policyMismatch }
            return current
        }
        let state = try BoneWorkflowRunBudget(runID: runID, policy: policy, started: now)
        budgets[runID] = state
        return state
    }

    public func load(runID: BoneRunID) throws -> BoneWorkflowRunBudget {
        try Task.checkCancellation()
        guard let state = budgets[runID] else { throw BoneWorkflowRunBudgetError.missingBudget }
        return state
    }

    public func reserve(runID: BoneRunID, expectedRevision: UInt64, phase: BoneWorkflowRunBudget.Phase,
                        now: BoneWorkflowRunBudget.Clock) throws -> BoneWorkflowRunBudget.Reservation {
        let state = try load(runID: runID)
        guard state.revision == expectedRevision else { throw BoneWorkflowRunBudgetError.revisionConflict }
        let reservation = try state.reserving(phase: phase, now: now)
        budgets[runID] = reservation.snapshot
        return reservation
    }
}
