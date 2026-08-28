import Foundation

/// 高风险 Tool 单次执行所需的全部稳定绑定；不携带原始 Prompt、凭据或 Tool 参数。
public struct BoneWorkflowToolExecutionContext: Sendable {
    public let ticketID: BoneAuthorizationTicketID
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let toolCallID: BoneToolCallID
    public let effectID: BoneEffectID
    public let principal: String
    public let resourceScope: String
    public let resourceRevision: UInt64
    public let authorizationNonce: String
    public let nowUptime: TimeInterval
    public let leaseGeneration: UInt64
    public let recoveryStrategy: BoneEffectRecoveryStrategy
    public let idempotencyKey: String?

    public init(
        ticketID: BoneAuthorizationTicketID,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        toolCallID: BoneToolCallID,
        effectID: BoneEffectID,
        principal: String,
        resourceScope: String,
        resourceRevision: UInt64,
        authorizationNonce: String,
        nowUptime: TimeInterval,
        leaseGeneration: UInt64,
        recoveryStrategy: BoneEffectRecoveryStrategy,
        idempotencyKey: String?
    ) throws {
        guard !principal.isEmpty, principal.count <= 128,
              !resourceScope.isEmpty, resourceScope.count <= 256,
              !authorizationNonce.isEmpty, authorizationNonce.count <= 128,
              nowUptime.isFinite, leaseGeneration > 0 else {
            throw BoneWorkflowToolExecutionError.invalidContext
        }
        self.ticketID = ticketID
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.toolCallID = toolCallID
        self.effectID = effectID
        self.principal = principal
        self.resourceScope = resourceScope
        self.resourceRevision = resourceRevision
        self.authorizationNonce = authorizationNonce
        self.nowUptime = nowUptime
        self.leaseGeneration = leaseGeneration
        self.recoveryStrategy = recoveryStrategy
        self.idempotencyKey = idempotencyKey
    }
}

/// 持久化 Store 的协议只接受 digest、opaque identity 与稳定状态，不接受原始参数/结果。
public protocol BoneWorkflowEffectStore: Sendable {
    /// 生产 Store 必须在同一事务内消费 Grant 并持久化 Intent；失败时两者一起回滚。
    func consumeAuthorizationAndPersistIntent(
        _ validation: BoneAuthorizationValidation,
        intent: BoneEffectIntent
    ) async throws
    func persistCancellation(effectID: BoneEffectID, leaseGeneration: UInt64) async throws
    /// 成功返回是“副作用可能已越过执行边界”的线性化点。此后即使 operation
    /// 抛出 CancellationError，也必须按结果未知恢复，不能解释为尚未执行。
    func markExecutionStarted(effectID: BoneEffectID, leaseGeneration: UInt64) async throws
    func recordReceipt(_ receipt: BoneEffectReceipt) async throws
    /// Host 实现必须在同一 transaction 内提交业务 Checkpoint bundle 与 Effect committed。
    func commitReceipt(effectID: BoneEffectID, leaseGeneration: UInt64) async throws
    /// currentLeaseGeneration 必须等于 Run 当前 lease；允许读取旧 execution lease 留下的事实。
    func recoverySnapshot(
        effectID: BoneEffectID,
        currentLeaseGeneration: UInt64
    ) async throws -> BoneEffectRecoverySnapshot?
    /// 将 executionStarted 无 Receipt 的不确定结果持久化，避免后续恢复重新进入普通执行路径。
    func persistOutcomeUnknown(effectID: BoneEffectID, currentLeaseGeneration: UInt64) async throws
    /// prepared Effect 从历史 execution lease 原子接管到当前 Run lease，再允许执行。
    func resumePreparedEffect(
        effectID: BoneEffectID,
        expectedExecutionLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws
    /// 使用当前 Run lease 原子提交历史 Receipt 与业务 Checkpoint bundle，不重执行 Tool。
    func commitRecoveredReceipt(
        effectID: BoneEffectID,
        receiptLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws
    /// 对账完成后，使用历史 execution lease + 当前 Run lease 持久化恢复 Receipt。
    func recordRecoveredReceipt(
        _ receipt: BoneEffectReceipt,
        expectedExecutionLeaseGeneration: UInt64,
        currentLeaseGeneration: UInt64
    ) async throws
}

/// 只在 Receipt 与业务 Checkpoint 原子提交完成后发布。
public struct BoneWorkflowToolCommitObserver: Sendable {
    private let receiveClosure: @Sendable (BoneEffectID, BoneEffectOutcome) async -> Void

    public init(_ receive: @escaping @Sendable (BoneEffectID, BoneEffectOutcome) async -> Void = { _, _ in }) {
        receiveClosure = receive
    }

    public func receive(effectID: BoneEffectID, outcome: BoneEffectOutcome) async {
        await receiveClosure(effectID, outcome)
    }
}
