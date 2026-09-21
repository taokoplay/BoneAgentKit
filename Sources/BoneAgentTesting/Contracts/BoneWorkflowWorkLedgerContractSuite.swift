import Foundation
import BoneAgentKit

public enum BoneWorkflowWorkLedgerContractCase: String, CaseIterable, Codable, Sendable {
    case pageCAS, generationFencing, knownFailure, splitStopsParent, preflightInFlight, aggregateCAS, concurrentCAS
}
public enum BoneWorkflowWorkLedgerContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, unexpectedAcceptance, unexpectedRejection, cleanupFailed
}
public struct BoneWorkflowWorkLedgerContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowWorkLedgerContractCase
    public let failures: [BoneWorkflowWorkLedgerContractFailure]
    public var passed: Bool { failures.isEmpty }
    public init(scenario: BoneWorkflowWorkLedgerContractCase, failures: [BoneWorkflowWorkLedgerContractFailure]) {
        self.scenario = scenario; self.failures = failures
    }
}
public struct BoneWorkflowWorkLedgerContractFixture: Sendable {
    public let store: any BoneWorkflowWorkLedgerStore
    public let cleanup: @Sendable () async throws -> Void
    /// 每次场景空且隔离的scope，cleanup必须关闭所有资源；factory返回前失败自行清理。
    public init(store: any BoneWorkflowWorkLedgerStore, cleanup: @escaping @Sendable () async throws -> Void) {
        self.store = store; self.cleanup = cleanup
    }
}

/// 行为探测，不认证跨表原子性/真实DB。报告固定白名单，不输出数据、标识或底层错误。
public struct BoneWorkflowWorkLedgerContractSuite: Sendable {
    public init() {}
    public func run(factory: @Sendable (BoneWorkflowWorkLedgerContractCase) async throws -> BoneWorkflowWorkLedgerContractFixture) async throws -> [BoneWorkflowWorkLedgerContractObservation] {
        var results: [BoneWorkflowWorkLedgerContractObservation] = []
        for scenario in BoneWorkflowWorkLedgerContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowWorkLedgerContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, failures: [.fixtureCreationFailed])); continue
            }
            var failures: [BoneWorkflowWorkLedgerContractFailure] = []
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
    private struct Violation: Error { let failure: BoneWorkflowWorkLedgerContractFailure }
    private func require(_ condition: Bool, _ failure: BoneWorkflowWorkLedgerContractFailure = .snapshotMismatch) throws {
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
    private func apply(_ old: BoneWorkflowWorkLedger, _ command: BoneWorkflowWorkLedger.Command,
                       store: any BoneWorkflowWorkLedgerStore) async throws -> BoneWorkflowWorkLedger {
        let saved = try await store.apply(runID: old.runID, expectedRevision: old.revision,
            leaseGeneration: old.leaseGeneration, command: command)
        try require(saved == old.applying(command, leaseGeneration: old.leaseGeneration))
        let loaded = try await store.load(runID: old.runID)
        try require(loaded == saved)
        return saved
    }
    private func probe(_ scenario: BoneWorkflowWorkLedgerContractCase, store: any BoneWorkflowWorkLedgerStore) async throws {
        let id = try BoneRunID("ledger-run")
        let seeds = [try BoneWorkflowWorkLedger.Seed(id: "unit", payload: Data([0xff, 0x00]))]
        let initial = try await store.open(runID: id, leaseGeneration: 1, units: seeds)
        try require(initial == BoneWorkflowWorkLedger(runID: id, leaseGeneration: 1, units: seeds))
        var current = initial
        switch scenario {
        case .aggregateCAS, .concurrentCAS:
            let split = try await apply(current, .split(unitID: "unit", children: [
                .init(id: "a", payload: Data([1])), .init(id: "b", payload: Data([2]))
            ]), store: store)
            if scenario == .aggregateCAS {
                current = try await apply(split, .reserve(unitID: "a", page: 0), store: store)
                try await rejected(.revisionConflict) {
                    _ = try await store.apply(runID: id, expectedRevision: split.revision, leaseGeneration: 1,
                        command: .reserve(unitID: "b", page: 0))
                }
            } else {
                let winners = try await withThrowingTaskGroup(of: BoneWorkflowWorkLedger?.self) { group in
                    for unitID in ["a", "b"] { group.addTask {
                        do {
                            let command = BoneWorkflowWorkLedger.Command.reserve(unitID: unitID, page: 0)
                            let saved = try await store.apply(runID: id, expectedRevision: split.revision, leaseGeneration: 1, command: command)
                            try require(saved == split.applying(command, leaseGeneration: 1))
                            return saved
                        } catch {
                            if error is CancellationError || Task.isCancelled { throw CancellationError() }
                            if error as? BoneWorkflowWorkLedgerError == .revisionConflict { return nil }
                            throw error
                        }
                    } }
                    var successes: [BoneWorkflowWorkLedger] = []
                    for try await result in group { if let result { successes.append(result) } }
                    return successes
                }
                try require(winners.count == 1)
                current = winners[0]
            }
        case .pageCAS:
            current = try await apply(current, .reserve(unitID: "unit", page: 0), store: store)
            try await rejected(.revisionConflict) {
                _ = try await store.apply(runID: id, expectedRevision: 1, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
            }
            current = try await apply(current, .dispatch(unitID: "unit", page: 0), store: store)
            current = try await apply(current, .recordResponse(unitID: "unit", page: 0, response: Data([3])), store: store)
            current = try await apply(current, .commit(unitID: "unit", page: 0, cursor: Data([4]), artifact: Data([5]), completed: false), store: store)
            let revision = current.revision
            try await rejected(.pageConflict) {
                _ = try await store.apply(runID: id, expectedRevision: revision, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
            }
            try require(current.unit(id: "unit").nextPage == 1 && current.unit(id: "unit").artifact == Data([5]))
        case .generationFencing:
            current = try await apply(current, .reserve(unitID: "unit", page: 0), store: store)
            current = try await apply(current, .dispatch(unitID: "unit", page: 0), store: store)
            let previous = current
            try await rejected(.revisionConflict) {
                _ = try await store.advanceLease(runID: id, expectedRevision: initial.revision, expectedGeneration: 1, newGeneration: 2)
            }
            let afterStaleLease = try await store.load(runID: id)
            try require(afterStaleLease == previous)
            for (old, new): (UInt64, UInt64) in [(0, 2), (1, 1), (1, 0)] {
                try await rejected(.leaseConflict) {
                    _ = try await store.advanceLease(runID: id, expectedRevision: previous.revision, expectedGeneration: old, newGeneration: new)
                }
                let unchanged = try await store.load(runID: id)
                try require(unchanged == previous)
            }
            current = try await store.advanceLease(runID: id, expectedRevision: current.revision, expectedGeneration: 1, newGeneration: 2)
            try require(current == previous.advancingLease(expectedGeneration: 1, newGeneration: 2))
            try require(current.preflight(unitID: "unit") == .recoveryRequired(page: 0))
            for generation: UInt64 in [1, 2] {
                let revision = current.revision
                try await rejected(generation == 1 ? .leaseConflict : .recoveryRequired) {
                    _ = try await store.apply(runID: id, expectedRevision: revision, leaseGeneration: generation,
                        command: .recordResponse(unitID: "unit", page: 0, response: Data([7])))
                }
            }
        case .knownFailure:
            current = try await apply(current, .reserve(unitID: "unit", page: 0), store: store)
            current = try await apply(current, .finishKnownFailure(unitID: "unit", page: 0), store: store)
            try require(current.unit(id: "unit").state == .partial && current.unit(id: "unit").nextPage == 1)
            try require(current.preflight(unitID: "unit") == .ready)
            current = try await apply(current, .reserve(unitID: "unit", page: 1), store: store)
            try require(current.unit(id: "unit").requestCount == 2)
        case .splitStopsParent:
            let children = [try BoneWorkflowWorkLedger.Seed(id: "a", payload: Data([1])), try .init(id: "b", payload: Data([2]))]
            try await rejected(.invalidInput) {
                _ = try await store.apply(runID: id, expectedRevision: 1, leaseGeneration: 1,
                    command: .split(unitID: "unit", children: [children[0], children[0]]))
            }
            let unchanged = try await store.load(runID: id)
            try require(unchanged == initial)
            current = try await apply(current, .split(unitID: "unit", children: children), store: store)
            try require(current.units.count == 3 && current.unit(id: "unit").state == .split)
            let revision = current.revision
            try await rejected(.invalidTransition) {
                _ = try await store.apply(runID: id, expectedRevision: revision, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
            }
            current = try await apply(current, .reserve(unitID: "a", page: 0), store: store)
        case .preflightInFlight:
            try require(current.preflight(unitID: "unit") == .ready)
            current = try await apply(current, .reserve(unitID: "unit", page: 0), store: store)
            try require(current.preflight(unitID: "unit") == .inFlight(page: 0, phase: .reserved))
            current = try await apply(current, .dispatch(unitID: "unit", page: 0), store: store)
            try require(current.preflight(unitID: "unit") == .inFlight(page: 0, phase: .dispatched))
            let revision = current.revision
            try await rejected(.inFlight) {
                _ = try await store.apply(runID: id, expectedRevision: revision, leaseGeneration: 1, command: .stop(unitID: "unit", reason: .noProgress))
            }
        }
        let loaded = try await store.load(runID: id)
        try require(loaded == current)
        let reopened = try await store.open(runID: id, leaseGeneration: current.leaseGeneration, units: seeds)
        try require(reopened == current)
        try Task.checkCancellation()
    }
}
