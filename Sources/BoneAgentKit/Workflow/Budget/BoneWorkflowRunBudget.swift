import Foundation

public enum BoneWorkflowRunBudgetError: Error, Codable, Equatable, Sendable {
    case invalidPolicy, invalidClock, corruptedBudget, policyMismatch, missingBudget, revisionConflict, counterOverflow
}

/// Run 级持久预算。与单次进程内 BoneRunBudgetMeter 独立；Host 必须原子保存 reserving 的结果。
/// 不含 session key，不提供退款/重置/隐式迁移。只读值推进本身不代表持久化成功。
public struct BoneWorkflowRunBudget: Codable, Equatable, Sendable {
    public struct Policy: Codable, Equatable, Sendable {
        public let versionTag: String
        public let requestLimit: UInt64
        public let reservedFinalRequests: UInt64
        public let durationSeconds: TimeInterval
        public let bootEpochToleranceSeconds: TimeInterval

        public init(versionTag: String, requestLimit: UInt64, reservedFinalRequests: UInt64,
                    durationSeconds: TimeInterval, bootEpochToleranceSeconds: TimeInterval = 1) throws {
            guard !versionTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, versionTag.count <= 128,
                  requestLimit > 0, reservedFinalRequests <= requestLimit,
                  durationSeconds.isFinite, durationSeconds > 0,
                  bootEpochToleranceSeconds.isFinite, bootEpochToleranceSeconds >= 0 else {
                throw BoneWorkflowRunBudgetError.invalidPolicy
            }
            self.versionTag = versionTag
            self.requestLimit = requestLimit
            self.reservedFinalRequests = reservedFinalRequests
            self.durationSeconds = durationSeconds
            self.bootEpochToleranceSeconds = bootEpochToleranceSeconds
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(versionTag: c.decode(String.self, forKey: .versionTag),
                requestLimit: c.decode(UInt64.self, forKey: .requestLimit),
                reservedFinalRequests: c.decode(UInt64.self, forKey: .reservedFinalRequests),
                durationSeconds: c.decode(TimeInterval.self, forKey: .durationSeconds),
                bootEpochToleranceSeconds: c.decode(TimeInterval.self, forKey: .bootEpochToleranceSeconds))
        }
    }

    /// Host 注入同一时刻的双时钟读数与稳定 boot 身份；不能为每个 session 新造 bootID。
    /// 不在构造时拒绝异常数值，以便 reserve 将异常原子记录为永久阻塞。
    public struct Clock: Codable, Equatable, Sendable {
        public let wallTime: TimeInterval
        public let uptime: TimeInterval
        public let bootID: String
        public init(wallTime: TimeInterval, uptime: TimeInterval, bootID: String) {
            self.wallTime = wallTime
            self.uptime = uptime
            self.bootID = bootID
        }
        fileprivate var valid: Bool {
            wallTime.isFinite && uptime.isFinite && uptime >= 0 && (wallTime - uptime).isFinite
                && !bootID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bootID.count <= 128
        }
    }

    /// phase 由 Host 可信业务流程选择，不能由模型/不可信请求自行指定 final 绕过保留额度。
    public enum Phase: String, Codable, Sendable { case ordinary, final }
    public enum Rejection: String, Codable, Sendable { case requestLimit, deadline, clockInvalid }
    public enum Decision: Equatable, Sendable { case granted, rejected(Rejection) }
    public struct Reservation: Equatable, Sendable {
        public let snapshot: BoneWorkflowRunBudget
        public let decision: Decision
        public init(snapshot: BoneWorkflowRunBudget, decision: Decision) {
            self.snapshot = snapshot
            self.decision = decision
        }
    }

    public let runID: BoneRunID
    public let policy: Policy
    public let started: Clock
    public let lastObserved: Clock
    public let usedRequests: UInt64
    /// 所有已持久化的预留尝试，包括预算拒绝；与消耗库存分开，拒绝不侵占 final 保留。
    public let attemptedRequests: UInt64
    public let revision: UInt64
    /// deadline/clockInvalid 一旦记录不会自动清除；requestLimit 是阶段相关拒绝，不永久锁死 final。
    public let blockedReason: Rejection?
    public var wallDeadline: TimeInterval { started.wallTime + policy.durationSeconds }
    public var uptimeDeadline: TimeInterval { started.uptime + policy.durationSeconds }

    public init(runID: BoneRunID, policy: Policy, started: Clock) throws {
        guard started.valid else { throw BoneWorkflowRunBudgetError.invalidClock }
        try self.init(runID: runID, policy: policy, started: started, lastObserved: started,
            usedRequests: 0, attemptedRequests: 0, revision: 1, blockedReason: nil)
    }

    private init(runID: BoneRunID, policy: Policy, started: Clock, lastObserved: Clock,
                 usedRequests: UInt64, attemptedRequests: UInt64, revision: UInt64, blockedReason: Rejection?) throws {
        guard started.valid, lastObserved.valid, revision > 0,
              usedRequests <= policy.requestLimit, usedRequests <= attemptedRequests,
              attemptedRequests == revision - 1,
              blockedReason != .requestLimit,
              (started.wallTime + policy.durationSeconds).isFinite,
              started.wallTime + policy.durationSeconds > started.wallTime,
              (started.uptime + policy.durationSeconds).isFinite,
              started.uptime + policy.durationSeconds > started.uptime,
              Self.clockRejection(start: started, last: started, now: lastObserved, policy: policy) == nil else {
            throw BoneWorkflowRunBudgetError.corruptedBudget
        }
        // Below the ordinary threshold every unblocked attempt must have been granted.
        // A gap here is unreachable and may incorrectly restore already spent inventory.
        if blockedReason == nil, usedRequests < policy.requestLimit - policy.reservedFinalRequests {
            guard attemptedRequests == usedRequests else { throw BoneWorkflowRunBudgetError.corruptedBudget }
        }
        if blockedReason != nil {
            guard attemptedRequests > usedRequests else { throw BoneWorkflowRunBudgetError.corruptedBudget }
        }
        let expired = lastObserved.wallTime >= started.wallTime + policy.durationSeconds
            || lastObserved.uptime >= started.uptime + policy.durationSeconds
        guard !expired || blockedReason == .deadline else { throw BoneWorkflowRunBudgetError.corruptedBudget }
        self.runID = runID
        self.policy = policy
        self.started = started
        self.lastObserved = lastObserved
        self.usedRequests = usedRequests
        self.attemptedRequests = attemptedRequests
        self.revision = revision
        self.blockedReason = blockedReason
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard schema == 1 else { throw BoneWorkflowRunBudgetError.corruptedBudget }
        try self.init(runID: c.decode(BoneRunID.self, forKey: .runID), policy: c.decode(Policy.self, forKey: .policy),
            started: c.decode(Clock.self, forKey: .started), lastObserved: c.decode(Clock.self, forKey: .lastObserved),
            usedRequests: c.decode(UInt64.self, forKey: .usedRequests), attemptedRequests: c.decode(UInt64.self, forKey: .attemptedRequests),
            revision: c.decode(UInt64.self, forKey: .revision), blockedReason: c.decodeIfPresent(Rejection.self, forKey: .blockedReason))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion)
        try c.encode(runID, forKey: .runID)
        try c.encode(policy, forKey: .policy)
        try c.encode(started, forKey: .started)
        try c.encode(lastObserved, forKey: .lastObserved)
        try c.encode(usedRequests, forKey: .usedRequests)
        try c.encode(attemptedRequests, forKey: .attemptedRequests)
        try c.encode(revision, forKey: .revision)
        try c.encodeIfPresent(blockedReason, forKey: .blockedReason)
    }

    /// 纯推进：合法调用产生下一版本，即便拒绝也记录 attemptedRequests；Store 须原子持久化后再返回。
    /// granted 后下游请求失败/取消不退款。提交结果未知时 load 调和，不能自动重试扣额。
    public func reserving(phase: Phase, now: Clock) throws -> Reservation {
        let (nextRevision, overflow) = revision.addingReportingOverflow(1)
        let (attempts, attemptOverflow) = attemptedRequests.addingReportingOverflow(1)
        guard !overflow && !attemptOverflow else { throw BoneWorkflowRunBudgetError.counterOverflow }
        var rejection = blockedReason
        var last = lastObserved
        if rejection == nil {
            rejection = Self.clockRejection(start: started, last: lastObserved, now: now, policy: policy)
            if rejection == nil {
                last = now
                if now.wallTime >= wallDeadline || now.uptime >= uptimeDeadline { rejection = .deadline }
            }
        }
        let blocked = rejection
        if rejection == nil {
            let limit = phase == .final ? policy.requestLimit : policy.requestLimit - policy.reservedFinalRequests
            if usedRequests >= limit { rejection = .requestLimit }
        }
        let granted = rejection == nil
        let snapshot = try Self(runID: runID, policy: policy, started: started, lastObserved: last,
            usedRequests: granted ? usedRequests + 1 : usedRequests, attemptedRequests: attempts,
            revision: nextRevision, blockedReason: blocked)
        return .init(snapshot: snapshot, decision: rejection.map { .rejected($0) } ?? .granted)
    }

    private static func clockRejection(start: Clock, last: Clock, now: Clock, policy: Policy) -> Rejection? {
        guard now.valid, now.bootID == start.bootID,
              now.wallTime >= last.wallTime, now.uptime >= last.uptime else { return .clockInvalid }
        let drift = abs((now.wallTime - now.uptime) - (start.wallTime - start.uptime))
        guard drift.isFinite, drift <= policy.bootEpochToleranceSeconds else { return .clockInvalid }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, policy, started, lastObserved, usedRequests, attemptedRequests, revision, blockedReason
    }
}
