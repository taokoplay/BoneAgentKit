import Foundation
import BoneAgentKit

public enum BoneWorkflowRunBudgetContractCase: String, CaseIterable, Codable, Sendable {
    case requestLimit, finalReserve, deadline, clockFencing, reopenPreservesBudget, policyDrift, concurrentCAS
}
public enum BoneWorkflowRunBudgetContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, unexpectedRejection, casWinnerCount, cleanupFailed
}
public enum BoneWorkflowRunBudgetContractOutcome: Equatable, Codable, Sendable {
    case passed
    /// 缺少测试 reopen 回调，不代表跨 session 保留不需要实现。
    case skippedReopen
    case failed([BoneWorkflowRunBudgetContractFailure])
}
public struct BoneWorkflowRunBudgetContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowRunBudgetContractCase
    public let outcome: BoneWorkflowRunBudgetContractOutcome
    public init(scenario: BoneWorkflowRunBudgetContractCase, outcome: BoneWorkflowRunBudgetContractOutcome) {
        self.scenario = scenario
        self.outcome = outcome
    }
}

/// 每个场景空且隔离的 scope；cleanup 负责全部连接和测试资源。不得访问生产数据。
public struct BoneWorkflowRunBudgetContractFixture: Sendable {
    public let store: any BoneWorkflowRunBudgetStore
    /// 关闭原连接并重开同一 backing；返回同一个 actor 或它的薄包装不算真实 reopen。
    public let reopen: (@Sendable () async throws -> any BoneWorkflowRunBudgetStore)?
    public let cleanup: @Sendable () async throws -> Void
    public init(store: any BoneWorkflowRunBudgetStore,
                reopen: (@Sendable () async throws -> any BoneWorkflowRunBudgetStore)? = nil,
                cleanup: @escaping @Sendable () async throws -> Void) {
        self.store = store
        self.reopen = reopen
        self.cleanup = cleanup
    }
}

/// 固定脱敏报告；验证预算/预留行为，不证明真实数据库隔离、boot 身份或磁盘持久性。
public struct BoneWorkflowRunBudgetContractSuite: Sendable {
    public init() {}
    public func run(factory: @Sendable (BoneWorkflowRunBudgetContractCase) async throws -> BoneWorkflowRunBudgetContractFixture) async throws -> [BoneWorkflowRunBudgetContractObservation] {
        var results: [BoneWorkflowRunBudgetContractObservation] = []
        for scenario in BoneWorkflowRunBudgetContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowRunBudgetContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, outcome: .failed([.fixtureCreationFailed])))
                continue
            }
            var outcome: BoneWorkflowRunBudgetContractOutcome
            var cancelled = false
            do { try Task.checkCancellation(); outcome = try await probe(scenario, fixture: fixture) }
            catch {
                cancelled = error is CancellationError || Task.isCancelled
                outcome = .failed([(error as? Violation)?.failure ?? .operationFailed])
            }
            let cleanup = fixture.cleanup
            do { try await Task.detached { try await cleanup() }.value }
            catch {
                cancelled = cancelled || error is CancellationError
                if case .failed(let failures) = outcome { outcome = .failed(failures + [.cleanupFailed]) }
                else { outcome = .failed([.cleanupFailed]) }
            }
            if cancelled || Task.isCancelled { throw CancellationError() }
            results.append(.init(scenario: scenario, outcome: outcome))
        }
        try Task.checkCancellation()
        return results
    }

    private struct Violation: Error { let failure: BoneWorkflowRunBudgetContractFailure }
    private func require(_ value: Bool, _ failure: BoneWorkflowRunBudgetContractFailure = .snapshotMismatch) throws {
        guard value else { throw Violation(failure: failure) }
    }
    private func clock(_ wall: Double = 1000, _ uptime: Double = 10, boot: String = "boot") -> BoneWorkflowRunBudget.Clock {
        .init(wallTime: wall, uptime: uptime, bootID: boot)
    }
    private func reserve(_ old: BoneWorkflowRunBudget, _ store: any BoneWorkflowRunBudgetStore,
                         phase: BoneWorkflowRunBudget.Phase, now: BoneWorkflowRunBudget.Clock,
                         decision: BoneWorkflowRunBudget.Decision) async throws -> BoneWorkflowRunBudget {
        let expected = try old.reserving(phase: phase, now: now)
        // Decision is independently specified so Core and adapter cannot agree on a wrong decision unnoticed.
        try require(expected.decision == decision)
        let actual = try await store.reserve(runID: old.runID, expectedRevision: old.revision, phase: phase, now: now)
        try require(actual == expected)
        let used = decision == .granted ? old.usedRequests + 1 : old.usedRequests
        try require(actual.snapshot.usedRequests == used && actual.snapshot.attemptedRequests == old.attemptedRequests + 1
            && actual.snapshot.revision == old.revision + 1 && actual.snapshot.started == old.started
            && actual.snapshot.policy == old.policy && actual.snapshot.runID == old.runID)
        let loaded = try await store.load(runID: old.runID)
        try require(loaded == expected.snapshot)
        return loaded
    }
    private func rejected(_ error: BoneWorkflowRunBudgetError, operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let actual {
            if actual is CancellationError || Task.isCancelled { throw CancellationError() }
            try require(actual as? BoneWorkflowRunBudgetError == error, .unexpectedRejection)
            return
        }
        throw Violation(failure: .unexpectedRejection)
    }
    private func probe(_ scenario: BoneWorkflowRunBudgetContractCase, fixture: BoneWorkflowRunBudgetContractFixture) async throws -> BoneWorkflowRunBudgetContractOutcome {
        if scenario == .reopenPreservesBudget && fixture.reopen == nil { return .skippedReopen }
        let store = fixture.store
        let id = try BoneRunID("budget-run")
        let policy = try BoneWorkflowRunBudget.Policy(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100)
        let initial = try await store.open(runID: id, policy: policy, now: clock())
        try require(initial == BoneWorkflowRunBudget(runID: id, policy: policy, started: clock()))
        var state = initial
        switch scenario {
        case .requestLimit:
            for _ in 0..<3 { state = try await reserve(state, store, phase: .final, now: clock(), decision: .granted) }
            state = try await reserve(state, store, phase: .final, now: clock(), decision: .rejected(.requestLimit))
            try require(state.usedRequests == 3 && state.attemptedRequests == 4)
        case .finalReserve:
            for _ in 0..<2 { state = try await reserve(state, store, phase: .ordinary, now: clock(), decision: .granted) }
            state = try await reserve(state, store, phase: .ordinary, now: clock(), decision: .rejected(.requestLimit))
            state = try await reserve(state, store, phase: .final, now: clock(), decision: .granted)
            try require(state.usedRequests == 3 && state.attemptedRequests == 4)
        case .deadline:
            state = try await reserve(state, store, phase: .final, now: clock(1100, 110), decision: .rejected(.deadline))
            state = try await reserve(state, store, phase: .final, now: clock(), decision: .rejected(.deadline))
            try require(state.usedRequests == 0 && state.attemptedRequests == 2)
        case .clockFencing:
            for (index, bad) in [clock(999, 11), clock(1001, 9), clock(1001, 11, boot: "new"), clock(1050, 11)].enumerated() {
                let run = try BoneRunID("clock-\(index)")
                let seed = try await store.open(runID: run, policy: policy, now: clock())
                let blocked = try await reserve(seed, store, phase: .final, now: bad, decision: .rejected(.clockInvalid))
                _ = try await reserve(blocked, store, phase: .final, now: clock(1002, 12), decision: .rejected(.clockInvalid))
            }
        case .reopenPreservesBudget:
            state = try await reserve(state, store, phase: .ordinary, now: clock(1001, 11), decision: .granted)
            guard let reopen = fixture.reopen else { return .skippedReopen }
            var blockedRows: [BoneWorkflowRunBudget] = []
            for (index, rejection) in [BoneWorkflowRunBudget.Rejection.clockInvalid, .deadline].enumerated() {
                let seed = try await store.open(runID: .init("blocked-\(index)"), policy: policy, now: clock())
                let bad = rejection == .deadline ? clock(1100, 110) : clock(999, 11)
                blockedRows.append(try await reserve(seed, store, phase: .final, now: bad, decision: .rejected(rejection)))
            }
            let newStore = try await reopen()
            for blocked in blockedRows {
                let restored = try await newStore.load(runID: blocked.runID)
                try require(restored == blocked)
                guard let reason = blocked.blockedReason else { throw Violation(failure: .snapshotMismatch) }
                _ = try await reserve(restored, newStore, phase: .final, now: clock(), decision: .rejected(reason))
            }
            let reopened = try await newStore.open(runID: id, policy: policy, now: clock(9000, 1, boot: "new"))
            try require(reopened == state)
            _ = try await reserve(reopened, newStore, phase: .final, now: clock(9000, 1, boot: "new"), decision: .rejected(.clockInvalid))
        case .policyDrift:
            for changed in [
                try BoneWorkflowRunBudget.Policy(versionTag: "v1", requestLimit: 4, reservedFinalRequests: 1, durationSeconds: 100),
                try .init(versionTag: "v2", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100),
                try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 0, durationSeconds: 100),
                try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 101),
                try .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100, bootEpochToleranceSeconds: 0),
                try .init(versionTag: "v2", requestLimit: 4, reservedFinalRequests: 1, durationSeconds: 101)
            ] {
                try await rejected(.policyMismatch) { _ = try await store.open(runID: id, policy: changed, now: clock()) }
                let unchanged = try await store.load(runID: id)
                try require(unchanged == state)
            }
        case .concurrentCAS:
            let now = clock()
            let wins = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 { group.addTask {
                    do {
                        let actual = try await store.reserve(runID: id, expectedRevision: initial.revision, phase: .ordinary, now: now)
                        try require(actual == initial.reserving(phase: .ordinary, now: now))
                        return true
                    } catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        if error as? BoneWorkflowRunBudgetError == .revisionConflict { return false }
                        throw error
                    }
                } }
                var count = 0
                for try await won in group { if won { count += 1 } }
                return count
            }
            try require(wins == 1, .casWinnerCount)
            let current = try await store.load(runID: id)
            try require(current == initial.reserving(phase: .ordinary, now: now).snapshot)
        }
        try Task.checkCancellation()
        return .passed
    }
}
