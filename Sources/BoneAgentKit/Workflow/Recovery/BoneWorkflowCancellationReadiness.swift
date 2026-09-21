import Foundation

/// Host 在同一事务或等价读屏障下读取 Run、当前 session、全历史 Effect、当前 stage 与 preflight。
/// 不允许分别读取后拼接成“完整”证据；数据库错误/取消必须抛出，不能替换为空集合或 true。
public protocol BoneWorkflowCancellationReadinessQuery: Sendable {
    func cancellationSnapshot(runID: BoneRunID) async throws -> BoneWorkflowCancellationSnapshot
}

/// 仅用于“从未开始的续执行”收口判定的只读投影，不是完整 session/Effect 存储模型。
/// 没有 Worker 字段：缺少进程内 Worker 不能证明执行已停止。
public struct BoneWorkflowCancellationSnapshot: Equatable, Sendable {
    public struct Session: Equatable, Sendable {
        public let id: String
        /// 零基序号：首次执行为 0，续执行从 1 起。Host 的一基编号必须先转换。
        public let sequence: UInt64
        public let revision: UInt64
        public let isActive: Bool
        public let hasObservation: Bool

        public init(id: String, sequence: UInt64, revision: UInt64, isActive: Bool, hasObservation: Bool) {
            self.id = id
            self.sequence = sequence
            self.revision = revision
            self.isActive = isActive
            self.hasObservation = hasObservation
        }
    }

    public struct Effect: Equatable, Sendable {
        public enum State: String, Codable, Sendable {
            /// 持久化提交已确认；仅收到 Receipt、执行成功或已应用部分结果都不够。
            case committed
            case uncommitted
            case outcomeUnknown
        }
        public let id: BoneEffectID
        public let sessionID: String
        public let state: State

        public init(id: BoneEffectID, sessionID: String, state: State) {
            self.id = id
            self.sessionID = sessionID
            self.state = state
        }
    }

    public struct Checks: Equatable, Sendable {
        /// 本次 session 存在任何 stage 工作/产物（不只是当前正在运行）就不能称为从未开始。
        public let hasStageActivity: Bool
        public let preflightPassed: Bool
        /// Host 领域扩展的额外否决；true 不能覆盖任一通用安全条件。
        public let hostAllowsClosure: Bool

        public init(hasStageActivity: Bool, preflightPassed: Bool, hostAllowsClosure: Bool) {
            self.hasStageActivity = hasStageActivity
            self.preflightPassed = preflightPassed
            self.hostAllowsClosure = hostAllowsClosure
        }
    }

    public let runID: BoneRunID
    public let runState: BoneWorkflowRunState
    public let runRevision: UInt64
    public let leaseGeneration: UInt64
    /// Host scope 内覆盖本快照全部事实的非零版本，任何相关变化均须推进，禁止回绕/复用。
    /// 不能仅复制 Run revision，除非 Host 保证所有 session/Effect/stage 变化也原子推进它。
    public let evidenceRevision: UInt64
    public let sessionComplete: Bool
    public let effectsComplete: Bool
    public let stagesComplete: Bool
    public let session: Session?
    public let effects: [Effect]
    public let checks: Checks

    public init(
        runID: BoneRunID, runState: BoneWorkflowRunState, runRevision: UInt64, leaseGeneration: UInt64,
        evidenceRevision: UInt64, sessionComplete: Bool, effectsComplete: Bool, stagesComplete: Bool,
        session: Session?, effects: [Effect], checks: Checks
    ) {
        self.runID = runID
        self.runState = runState
        self.runRevision = runRevision
        self.leaseGeneration = leaseGeneration
        self.evidenceRevision = evidenceRevision
        self.sessionComplete = sessionComplete
        self.effectsComplete = effectsComplete
        self.stagesComplete = stagesComplete
        self.session = session
        self.effects = effects
        self.checks = checks
    }
}

public enum BoneWorkflowCancellationRejection: String, Codable, Sendable {
    case identityMismatch, incompleteEvidence, invalidEvidence, missingSession
    case cancellationNotPersisted, notContinuation, inactiveSession, observationPresent
    case unknownEffect, currentSessionHasEffects, uncommittedEffect
    case stageActivity, preflightRejected, hostRejected
}

public enum BoneWorkflowCancellationDecision: Equatable, Sendable {
    /// 仅表示该完整快照满足“从未开始续执行”的规则，不是持久化收口/停止证明或执行授权。
    case ready
    case rejected(BoneWorkflowCancellationRejection)
}

/// 绑定查询时的事实版本；不是 lease、取消凭据或可复用 token。Host 必须在最终事务内复核。
public struct BoneWorkflowCancellationEvaluation: Equatable, Sendable {
    public let runID: BoneRunID
    public let runRevision: UInt64
    public let leaseGeneration: UInt64
    public let evidenceRevision: UInt64
    public let decision: BoneWorkflowCancellationDecision

    init(runID: BoneRunID, snapshot: BoneWorkflowCancellationSnapshot, decision: BoneWorkflowCancellationDecision) {
        self.runID = runID
        self.runRevision = snapshot.runRevision
        self.leaseGeneration = snapshot.leaseGeneration
        self.evidenceRevision = snapshot.evidenceRevision
        self.decision = decision
    }
}

/// Fail-closed 只读判定，不改写 Run、Effect、stage 或已应用结果，不推断 Worker 状态。
public struct BoneWorkflowCancellationReadiness: Sendable {
    public init() {}

    public func evaluate(runID: BoneRunID, query: any BoneWorkflowCancellationReadinessQuery) async throws -> BoneWorkflowCancellationEvaluation {
        try Task.checkCancellation()
        let snapshot = try await query.cancellationSnapshot(runID: runID)
        try Task.checkCancellation()
        guard snapshot.runID == runID else {
            return .init(runID: runID, snapshot: snapshot, decision: .rejected(.identityMismatch))
        }
        return evaluate(snapshot)
    }

    public func evaluate(_ snapshot: BoneWorkflowCancellationSnapshot) -> BoneWorkflowCancellationEvaluation {
        .init(runID: snapshot.runID, snapshot: snapshot, decision: decision(snapshot))
    }

    private func decision(_ s: BoneWorkflowCancellationSnapshot) -> BoneWorkflowCancellationDecision {
        guard s.sessionComplete && s.effectsComplete && s.stagesComplete else { return .rejected(.incompleteEvidence) }
        guard s.runRevision > 0, s.evidenceRevision > 0,
              Set(s.effects.map(\.id)).count == s.effects.count,
              s.effects.allSatisfy({ validID($0.sessionID) }) else { return .rejected(.invalidEvidence) }
        guard let session = s.session else { return .rejected(.missingSession) }
        guard validID(session.id), session.revision > 0 else { return .rejected(.invalidEvidence) }
        guard s.runState == .cancelling || s.runState == .cancelled else { return .rejected(.cancellationNotPersisted) }
        guard session.sequence > 0 else { return .rejected(.notContinuation) }
        guard session.isActive else { return .rejected(.inactiveSession) }
        guard !session.hasObservation else { return .rejected(.observationPresent) }
        // Both current and historical unknown effects veto closure, regardless of Host policy.
        guard !s.effects.contains(where: { $0.state == .outcomeUnknown }) else { return .rejected(.unknownEffect) }
        guard !s.effects.contains(where: { $0.sessionID == session.id }) else { return .rejected(.currentSessionHasEffects) }
        guard s.effects.allSatisfy({ $0.state == .committed }) else { return .rejected(.uncommittedEffect) }
        guard !s.checks.hasStageActivity else { return .rejected(.stageActivity) }
        guard s.checks.preflightPassed else { return .rejected(.preflightRejected) }
        guard s.checks.hostAllowsClosure else { return .rejected(.hostRejected) }
        return .ready
    }

    private func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
