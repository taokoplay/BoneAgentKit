import Foundation

public enum BoneWorkflowRecoveryReason: String, Codable, Equatable, Sendable {
    case outcomeUnknown
    case fencingConflict
    case receiptMismatch
}

public enum BoneWorkflowRecoveryAction: Codable, Equatable, Sendable {
    case execute
    case reexecuteWithSameIdentity
    case reconcile
    case reconcileBeforeCompensation
    case cancelWithoutExecution
    case commitReceipt
    case completed
    case recoveryRequired(BoneWorkflowRecoveryReason)
}

public struct BoneEffectRecoverySnapshot: Codable, Equatable, Sendable {
    public let intent: BoneEffectIntent
    public let receipt: BoneEffectReceipt?
    public let stepCommitted: Bool
    public let cancellationPersisted: Bool

    public init(
        intent: BoneEffectIntent,
        receipt: BoneEffectReceipt?,
        stepCommitted: Bool,
        cancellationPersisted: Bool
    ) {
        self.intent = intent
        self.receipt = receipt
        self.stepCommitted = stepCommitted
        self.cancellationPersisted = cancellationPersisted
    }
}

public struct BoneWorkflowRecoveryPlanner: Sendable {
    public init() {}

    public func plan(_ snapshot: BoneEffectRecoverySnapshot) -> BoneWorkflowRecoveryAction {
        if snapshot.stepCommitted { return .completed }
        if let receipt = snapshot.receipt {
            guard receipt.effectID == snapshot.intent.id else {
                return .recoveryRequired(.receiptMismatch)
            }
            guard receipt.leaseGeneration == snapshot.intent.leaseGeneration else {
                return .recoveryRequired(.fencingConflict)
            }
            return .commitReceipt
        }
        if snapshot.intent.phase == .intentPersisted {
            return snapshot.cancellationPersisted ? .cancelWithoutExecution : .execute
        }
        switch snapshot.intent.recoveryStrategy {
        case .naturallyIdempotent, .idempotencyKeyRequired:
            // executionStarted 后缺少 Receipt 时，不能从“幂等声明”推导第一次执行的真实结果；
            // 生产管线不盲目重试，交由 Host/用户显式恢复。
            return .recoveryRequired(.outcomeUnknown)
        case .reconcilable:
            return .reconcile
        case .compensatable:
            return .reconcileBeforeCompensation
        case .nonRecoverableRequiresUserDecision:
            return .recoveryRequired(.outcomeUnknown)
        }
    }
}
