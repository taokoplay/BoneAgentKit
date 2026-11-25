import Foundation

/// 一次 Agent Session 对高风险 Tool 执行提供的完整身份围栏。
public struct BoneWorkflowExecutionScope: Sendable, Equatable {
    /// 长期 Agent Session 身份。旧 Workflow 调用可以为空，新 Session 路径必须提供。
    public let sessionID: String?
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let leaseGeneration: UInt64

    /// 创建 Tool 执行作用域。
    /// - Parameters:
    ///   - sessionID: 可选的长期 Agent Session 身份。
    ///   - runID: 当前 Workflow Run 身份。
    ///   - stepID: 当前 Workflow Step 身份。
    ///   - attemptID: 当前执行 Attempt 身份。
    ///   - leaseGeneration: 当前执行代际，必须大于零。
    /// - Throws: 身份为空或 lease 无效时抛出 Tool 上下文错误。
    public init(
        sessionID: String? = nil,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        leaseGeneration: UInt64
    ) throws {
        if let sessionID {
            guard !sessionID.isEmpty, sessionID.count <= 128 else {
                throw BoneWorkflowToolExecutionError.invalidContext
            }
        }
        guard leaseGeneration > 0 else { throw BoneWorkflowToolExecutionError.invalidContext }
        self.sessionID = sessionID
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.leaseGeneration = leaseGeneration
    }
}

/// 当前结构化 Agent 执行作用域，供 Host 的 Tool Context Provider 读取。
public enum BoneWorkflowExecutionScopeContext {
    /// Coordinator 在恢复 Session 的模型调用期间设置的作用域。
    @TaskLocal public static var current: BoneWorkflowExecutionScope?
}

/// Effect 恢复时用于校验持久化 Intent 归属的稳定身份。
public struct BoneWorkflowEffectRecoveryScope: Sendable, Equatable {
    /// 预期的长期 Agent Session 身份。旧 Effect 没有该字段时保留兼容读取能力。
    public let sessionID: String?
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID

    /// 创建 Effect 恢复归属校验范围。
    /// - Parameters: 当前 Session 对应的 Session、Run、Step 和 Attempt 身份。
    /// - Returns: 可传入恢复管线的不可变归属范围。
    public init(
        sessionID: String? = nil,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID
    ) {
        self.sessionID = sessionID
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
    }

    /// 验证 Effect Intent 是否属于当前恢复范围。
    /// - Parameter intent: Effect Store 返回的持久化 Intent。
    /// - Returns: 四项身份全部匹配时返回 true。
    public func matches(_ intent: BoneEffectIntent) -> Bool {
        guard intent.runID == runID,
              intent.stepID == stepID,
              intent.attemptID == attemptID else {
            return false
        }
        guard let sessionID else { return true }
        return intent.sessionID == sessionID
    }
}

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
    /// 当前 Tool 调用所属的 Agent Session、Run、Step、Attempt 和 lease 作用域。
    public let executionScope: BoneWorkflowExecutionScope?

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
        idempotencyKey: String?,
        executionScope: BoneWorkflowExecutionScope? = nil
    ) throws {
        guard !principal.isEmpty, principal.count <= 128,
              !resourceScope.isEmpty, resourceScope.count <= 256,
              !authorizationNonce.isEmpty, authorizationNonce.count <= 128,
              nowUptime.isFinite, leaseGeneration > 0 else {
            throw BoneWorkflowToolExecutionError.invalidContext
        }
        if let executionScope {
            guard executionScope.runID == runID,
                  executionScope.stepID == stepID,
                  executionScope.attemptID == attemptID,
                  executionScope.leaseGeneration == leaseGeneration else {
                throw BoneWorkflowToolExecutionError.identityMismatch
            }
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
        self.executionScope = executionScope
    }
}

/// 持久化 Store 的协议只接受 digest、opaque identity 与稳定状态，不接受原始参数/结果。
public protocol BoneWorkflowEffectStore: Sendable {
    /// 生产 Store 必须在同一事务内消费 Grant 并持久化 Intent。确定拒绝不改事实；
    /// 提交回执丢失时允许抛错但结果未知，调用方必须重读，不得把 throw 视为已回滚。
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
