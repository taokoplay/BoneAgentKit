import Foundation
import BoneAgentKit

public enum BoneWorkflowWorkReconciliationContractCase: String, CaseIterable, Codable, Sendable {
    case committedRecovery, knownFailureRetention, targetFencing, responseIntegrity, concurrentCAS, concurrentUnits, concurrentLease, phaseCoverage
}
public enum BoneWorkflowWorkReconciliationContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, unexpectedAcceptance, unexpectedRejection, cleanupFailed
}
public struct BoneWorkflowWorkReconciliationContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowWorkReconciliationContractCase
    public let failures: [BoneWorkflowWorkReconciliationContractFailure]
    public var passed: Bool { failures.isEmpty }
    public init(scenario: BoneWorkflowWorkReconciliationContractCase, failures: [BoneWorkflowWorkReconciliationContractFailure]) {
        self.scenario = scenario; self.failures = failures
    }
}
public struct BoneWorkflowWorkReconciliationContractFixture: Sendable {
    public let store: any BoneWorkflowWorkReconciliationStore
    public let cleanup: @Sendable () async throws -> Void
    /// 每次场景空且隔离的scope，cleanup必须关闭所有资源；factory返回前失败自行清理。
    public init(store: any BoneWorkflowWorkReconciliationStore, cleanup: @escaping @Sendable () async throws -> Void) {
        self.store = store; self.cleanup = cleanup
    }
}

/// 行为探测，不认证跨表原子性/真实DB。报告固定白名单，不输出数据、标识或底层错误。
public struct BoneWorkflowWorkReconciliationContractSuite: Sendable {
    public init() {}
    public func run(factory: @Sendable (BoneWorkflowWorkReconciliationContractCase) async throws -> BoneWorkflowWorkReconciliationContractFixture) async throws -> [BoneWorkflowWorkReconciliationContractObservation] {
        var results: [BoneWorkflowWorkReconciliationContractObservation] = []
        for scenario in BoneWorkflowWorkReconciliationContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowWorkReconciliationContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, failures: [.fixtureCreationFailed])); continue
            }
            var failures: [BoneWorkflowWorkReconciliationContractFailure] = []
            var cancelled = false
            do { try Task.checkCancellation(); try await probe(scenario, store: fixture.store) }
            catch {
                cancelled = error is CancellationError || Task.isCancelled
                failures.append((error as? Violation)?.failure ?? .operationFailed)
            }
            let cleanup = fixture.cleanup
            do { try await Task.detached { try await cleanup() }.value }
            catch { cancelled = cancelled || error is CancellationError; failures.append(.cleanupFailed) }
            if cancelled || Task.isCancelled { throw CancellationError() }
            results.append(.init(scenario: scenario, failures: failures))
        }
        try Task.checkCancellation()
        return results
    }
    private struct Violation: Error { let failure: BoneWorkflowWorkReconciliationContractFailure }
    private func require(_ condition: Bool, _ failure: BoneWorkflowWorkReconciliationContractFailure = .snapshotMismatch) throws {
        guard condition else { throw Violation(failure: failure) }
    }
    private func rejected(_ error: BoneWorkflowWorkLedgerError, operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let actual {
            if actual is CancellationError || Task.isCancelled { throw CancellationError() }
            try require(actual as? BoneWorkflowWorkLedgerError == error, .unexpectedRejection); return
        }
        throw Violation(failure: .unexpectedAcceptance)
    }
    private typealias Ledger = BoneWorkflowWorkLedger
    private func request(_ state: Ledger, outcome: Ledger.Reconciliation.Outcome, runID: BoneRunID? = nil,
                         unitID: String = "unit", page: UInt64 = 1, source: UInt64 = 1,
                         generation: UInt64? = nil, revision: UInt64? = nil) throws -> Ledger.Reconciliation {
        try .init(runID: runID ?? state.runID, unitID: unitID, page: page, sourceGeneration: source,
            resolvingGeneration: generation ?? state.leaseGeneration, expectedRevision: revision ?? state.revision,
            evidenceID: "host-evidence", outcome: outcome)
    }
    private func reject(_ request: Ledger.Reconciliation, error: BoneWorkflowWorkLedgerError,
                        state: Ledger, store: any BoneWorkflowWorkReconciliationStore) async throws {
        try await rejected(error) { _ = try await store.reconcile(request) }
        let unchanged = try await store.load(runID: state.runID)
        try require(unchanged == state)
    }
    private func apply(_ state: Ledger, _ command: Ledger.Command, store: any BoneWorkflowWorkReconciliationStore) async throws -> Ledger {
        let updated = try await store.apply(runID: state.runID, expectedRevision: state.revision,
            leaseGeneration: state.leaseGeneration, command: command)
        try require(updated == state.applying(command, leaseGeneration: state.leaseGeneration))
        return updated
    }
    private func probeMixedConcurrency(_ scenario: BoneWorkflowWorkReconciliationContractCase,
                                       store: any BoneWorkflowWorkReconciliationStore) async throws {
        let id = try BoneRunID("concurrent-run")
        var state = try await store.open(runID: id, leaseGeneration: 1, units: [
            .init(id: "a", payload: Data()), .init(id: "b", payload: Data())
        ])
        for unit in ["a", "b"] {
            state = try await apply(state, .reserve(unitID: unit, page: 0), store: store)
        }
        let before = state
        state = try await store.advanceLease(runID: id, expectedRevision: state.revision, expectedGeneration: 1, newGeneration: 3)
        try require(state == before.advancingLease(expectedGeneration: 1, newGeneration: 3))
        let taken = state
        let a = try request(taken, outcome: .knownFailure, unitID: "a", page: 0)
        let b = try request(taken, outcome: .knownFailure, unitID: "b", page: 0)
        let expectedA = try taken.reconciling(a)
        let expectedB = try scenario == .concurrentUnits ? taken.reconciling(b) : taken.advancingLease(expectedGeneration: 3, newGeneration: 4)
        let winners = try await withThrowingTaskGroup(of: Ledger?.self) { group in
            for index in 0..<2 { group.addTask {
                do {
                    if index == 0 { return try await store.reconcile(a) }
                    if scenario == .concurrentUnits { return try await store.reconcile(b) }
                    return try await store.advanceLease(runID: id, expectedRevision: taken.revision, expectedGeneration: 3, newGeneration: 4)
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    if error as? BoneWorkflowWorkLedgerError == .revisionConflict { return nil }
                    throw error
                }
            } }
            var results: [Ledger] = []
            for try await value in group { if let value { results.append(value) } }
            return results
        }
        try require(winners.count == 1)
        let winner = winners[0]
        try require(winner == expectedA || winner == expectedB)
        let loaded = try await store.load(runID: id)
        try require(loaded == winner)
        // Deterministic cross-target stale CAS probe, in addition to scheduler-dependent overlap.
        let stale = winner == expectedA ? b : a
        try await reject(stale, error: .revisionConflict, state: winner, store: store)
    }
    private func probePhases(store: any BoneWorkflowWorkReconciliationStore) async throws {
        let id = try BoneRunID("phase-run")
        var state = try await store.open(runID: id, leaseGeneration: 1, units: [.init(id: "unit", payload: Data())])
        state = try await apply(state, .reserve(unitID: "unit", page: 0), store: store)
        let before = state
        state = try await store.advanceLease(runID: id, expectedRevision: state.revision, expectedGeneration: 1, newGeneration: 2)
        try require(state == before.advancingLease(expectedGeneration: 1, newGeneration: 2))
        let success = Ledger.Reconciliation.Outcome.committed(response: Data([1]), cursor: nil, artifact: Data([2]), completed: true)
        try await reject(request(state, outcome: success, page: 0), error: .invalidTransition, state: state, store: store)
        try await reject(request(state, outcome: .knownFailure, page: 0, revision: state.revision - 1), error: .revisionConflict, state: state, store: store)
        let failure = try request(state, outcome: .knownFailure, page: 0)
        let failed = try await store.reconcile(failure)
        try require(failed == state.reconciling(failure))
        var next = try await apply(failed, .reserve(unitID: "unit", page: 1), store: store)
        next = try await apply(next, .dispatch(unitID: "unit", page: 1), store: store)
        let beforeSecond = next
        next = try await store.advanceLease(runID: id, expectedRevision: next.revision, expectedGeneration: 2, newGeneration: 3)
        try require(next == beforeSecond.advancingLease(expectedGeneration: 2, newGeneration: 3))
        let commit = try request(next, outcome: success, source: 2)
        let completed = try await store.reconcile(commit)
        try require(completed == next.reconciling(commit))
        try require(completed.preflight(unitID: "unit") == .terminal(.completed))
        try await reject(request(completed, outcome: success, source: 2), error: .invalidTransition, state: completed, store: store)
        try await rejected(.invalidTransition) {
            _ = try await store.apply(runID: id, expectedRevision: completed.revision, leaseGeneration: 3,
                command: .reserve(unitID: "unit", page: 2))
        }
        let loaded = try await store.load(runID: id)
        try require(loaded == completed)
    }
    private func probe(_ scenario: BoneWorkflowWorkReconciliationContractCase, store: any BoneWorkflowWorkReconciliationStore) async throws {
        if scenario == .concurrentUnits || scenario == .concurrentLease {
            try await probeMixedConcurrency(scenario, store: store)
            return
        }
        if scenario == .phaseCoverage {
            try await probePhases(store: store)
            return
        }
        let runID = try BoneRunID("reconcile-run")
        let seeds = [try Ledger.Seed(id: "unit", payload: Data([0xff]))]
        var state = try await store.open(runID: runID, leaseGeneration: 1, units: seeds)
        try require(state == Ledger(runID: runID, leaseGeneration: 1, units: seeds))
        // Existing committed progress must survive reconciliation of the later page.
        state = try await apply(state, .reserve(unitID: "unit", page: 0), store: store)
        state = try await apply(state, .dispatch(unitID: "unit", page: 0), store: store)
        state = try await apply(state, .recordResponse(unitID: "unit", page: 0, response: Data([1])), store: store)
        state = try await apply(state, .commit(unitID: "unit", page: 0, cursor: Data([2]), artifact: Data([3]), completed: false), store: store)
        state = try await apply(state, .reserve(unitID: "unit", page: 1), store: store)
        state = try await apply(state, .dispatch(unitID: "unit", page: 1), store: store)
        if scenario == .responseIntegrity || scenario == .committedRecovery {
            state = try await apply(state, .recordResponse(unitID: "unit", page: 1, response: Data([4])), store: store)
        }
        let beforeLease = state
        state = try await store.advanceLease(runID: runID, expectedRevision: state.revision, expectedGeneration: 1, newGeneration: 3)
        try require(state == beforeLease.advancingLease(expectedGeneration: 1, newGeneration: 3))
        let taken = state
        try require(state.preflight(unitID: "unit") == .recoveryRequired(page: 1))
        let success = Ledger.Reconciliation.Outcome.committed(response: Data([4]), cursor: Data([5]), artifact: Data([6]), completed: false)
        let outcome: Ledger.Reconciliation.Outcome = scenario == .knownFailureRetention ? .knownFailure : success
        let valid = try request(state, outcome: outcome)
        // All cases require CAS and old Worker fencing to remain intact.
        try await reject(request(state, outcome: outcome, revision: state.revision - 1), error: .revisionConflict, state: state, store: store)
        for generation: UInt64 in [1, 3] {
            try await rejected(generation == 1 ? .leaseConflict : .recoveryRequired) {
                _ = try await store.apply(runID: runID, expectedRevision: taken.revision, leaseGeneration: generation,
                    command: .recordResponse(unitID: "unit", page: 1, response: Data([4])))
            }
            let unchanged = try await store.load(runID: runID)
            try require(unchanged == taken)
        }
        switch scenario {
        case .targetFencing:
            for (request, error) in [
                (try request(state, outcome: success, unitID: "missing"), BoneWorkflowWorkLedgerError.missingUnit),
                (try request(state, outcome: success, page: 0), .pageConflict),
                (try request(state, outcome: success, source: 2), .leaseConflict),
                (try request(state, outcome: success, generation: 2), .leaseConflict),
                (try request(state, outcome: success, runID: .init("unknown")), .missingLedger)
            ] { try await reject(request, error: error, state: state, store: store) }
            let otherID = try BoneRunID("other-run")
            let other = try await store.open(runID: otherID, leaseGeneration: 1, units: seeds)
            try require(other.runID == otherID)
            try await reject(request(state, outcome: success, runID: otherID), error: .revisionConflict, state: state, store: store)
            let otherAfter = try await store.load(runID: otherID)
            try require(otherAfter == other)
        case .responseIntegrity:
            try await reject(request(state, outcome: .knownFailure), error: .invalidTransition, state: state, store: store)
            try await reject(request(state, outcome: .committed(response: Data([9]), cursor: nil, artifact: Data(), completed: false)),
                error: .invalidInput, state: state, store: store)
        default: break
        }
        if scenario == .concurrentCAS {
            let winners = try await withThrowingTaskGroup(of: Ledger?.self) { group in
                for _ in 0..<2 { group.addTask {
                    do { return try await store.reconcile(valid) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        if error as? BoneWorkflowWorkLedgerError == .revisionConflict { return nil }
                        throw error
                    }
                } }
                var winners: [Ledger] = []
                for try await result in group { if let result { winners.append(result) } }
                return winners
            }
            try require(winners.count == 1)
            state = winners[0]
        } else { state = try await store.reconcile(valid) }
        try require(state == taken.reconciling(valid))
        let loaded = try await store.load(runID: runID)
        try require(loaded == state)
        try await reject(valid, error: .revisionConflict, state: state, store: store)
        try await reject(request(state, outcome: outcome), error: .invalidTransition, state: state, store: store)
        let unit = try state.unit(id: "unit")
        try require(unit.pages[0] == taken.unit(id: "unit").pages[0])
        try require(unit.pages[1].leaseGeneration == 1 && unit.pages[1].reconciliation == valid)
        try require(unit.nextPage == 2 && unit.requestCount == 2 && unit.state == .partial)
        if scenario == .knownFailureRetention { try require(unit.cursor == Data([2]) && unit.artifact == Data([3])) }
        try require(state.preflight(unitID: "unit") == .ready)
        state = try await apply(state, .reserve(unitID: "unit", page: 2), store: store)
        try require(state.unit(id: "unit").pages.last?.leaseGeneration == 3)
        let reopened = try await store.open(runID: runID, leaseGeneration: 3, units: seeds)
        try require(reopened == state)
        try Task.checkCancellation()
    }
}
