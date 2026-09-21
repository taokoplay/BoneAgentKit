import Foundation
import BoneAgentKit

public enum BoneWorkflowExecutionSessionContractCase: String, CaseIterable, Codable, Sendable {
    case admissionIntegrity, sequenceContinuity, nonceSingleUse, bindingMismatch, concurrentConsumption
}
public enum BoneWorkflowExecutionSessionContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, unexpectedAcceptance, unexpectedRejection, cleanupFailed
}
public struct BoneWorkflowExecutionSessionContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowExecutionSessionContractCase
    public let failures: [BoneWorkflowExecutionSessionContractFailure]
    public var passed: Bool { failures.isEmpty }
    public init(scenario: BoneWorkflowExecutionSessionContractCase, failures: [BoneWorkflowExecutionSessionContractFailure]) {
        self.scenario = scenario; self.failures = failures
    }
}
public struct BoneWorkflowExecutionSessionContractFixture: Sendable {
    public let store: any BoneWorkflowExecutionSessionStore
    public let cleanup: @Sendable () async throws -> Void
    /// 每场景空隔离scope，cleanup负责所有资源，factory返回前异常自行清理。
    public init(store: any BoneWorkflowExecutionSessionStore, cleanup: @escaping @Sendable () async throws -> Void) {
        self.store = store; self.cleanup = cleanup
    }
}
public struct BoneWorkflowExecutionSessionContractSuite: Sendable {
    public init() {}
    public func run(factory: @Sendable (BoneWorkflowExecutionSessionContractCase) async throws -> BoneWorkflowExecutionSessionContractFixture) async throws -> [BoneWorkflowExecutionSessionContractObservation] {
        var results: [BoneWorkflowExecutionSessionContractObservation] = []
        for scenario in BoneWorkflowExecutionSessionContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowExecutionSessionContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, failures: [.fixtureCreationFailed])); continue
            }
            var failures: [BoneWorkflowExecutionSessionContractFailure] = []
            var cancelled = false
            do { try Task.checkCancellation(); try await probe(scenario, store: fixture.store) }
            catch { cancelled = error is CancellationError || Task.isCancelled; failures.append((error as? Violation)?.failure ?? .operationFailed) }
            let cleanup = fixture.cleanup
            do { try await Task.detached { try await cleanup() }.value }
            catch { cancelled = cancelled || error is CancellationError; failures.append(.cleanupFailed) }
            if cancelled || Task.isCancelled { throw CancellationError() }
            results.append(.init(scenario: scenario, failures: failures))
        }
        try Task.checkCancellation()
        return results
    }
    private struct Violation: Error { let failure: BoneWorkflowExecutionSessionContractFailure }
    private func require(_ condition: Bool, _ failure: BoneWorkflowExecutionSessionContractFailure = .snapshotMismatch) throws {
        guard condition else { throw Violation(failure: failure) }
    }
    private func rejected(_ expected: BoneWorkflowExecutionSessionError, operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            try require(error as? BoneWorkflowExecutionSessionError == expected, .unexpectedRejection); return
        }
        throw Violation(failure: .unexpectedAcceptance)
    }
    private func request(_ sequence: UInt64, admission: Data = Data([0xff, 0x00]), binding: String = String(repeating: "a", count: 64), operation: String? = nil, effect: String? = nil) throws -> BoneWorkflowExecutionSession.Request {
        try .init(sequence: sequence, operationID: operation ?? "op-\(sequence)", effectID: .init(effect ?? "effect-\(sequence)"), bindingHash: binding, admission: admission)
    }
    private func apply(_ old: BoneWorkflowSessionLedger, _ command: BoneWorkflowSessionLedger.Command,
                       store: any BoneWorkflowExecutionSessionStore) async throws -> BoneWorkflowSessionLedger {
        // Every command, not only consume, must reject a stale aggregate revision before changing facts.
        try await rejected(.revisionConflict) {
            _ = try await store.apply(runID: old.runID, expectedRevision: old.revision - 1, command: command)
        }
        let unchanged = try await store.load(runID: old.runID)
        try require(unchanged == old)
        let saved = try await store.apply(runID: old.runID, expectedRevision: old.revision, command: command)
        try require(saved == old.applying(command))
        let read = try await store.load(runID: old.runID)
        try require(read == saved)
        return saved
    }
    private func rejectCommand(_ old: BoneWorkflowSessionLedger, _ command: BoneWorkflowSessionLedger.Command,
                               error: BoneWorkflowExecutionSessionError, store: any BoneWorkflowExecutionSessionStore) async throws {
        try await rejected(error) { _ = try await store.apply(runID: old.runID, expectedRevision: old.revision, command: command) }
        let unchanged = try await store.load(runID: old.runID)
        try require(unchanged == old)
    }
    private func probe(_ scenario: BoneWorkflowExecutionSessionContractCase, store: any BoneWorkflowExecutionSessionStore) async throws {
        let initial = try request(0)
        var state = try await store.open(runID: .init("session-run"), initial: initial)
        try require(state.runID == BoneRunID("session-run"))
        try require(state.sessions.count == 1 && state.current.sequence == 0 && state.current.admission == initial.admission)
        try require(state.current.state == .active && state.revision == 1)
        state = try await apply(state, .finish(.completed), store: store)
        let next = try request(1)
        switch scenario {
        case .sequenceContinuity:
            try await rejectCommand(state, .prepare(request(2), nonce: "nonce"), error: .sequenceConflict, store: store)
            try await rejectCommand(state, .consume(next, nonce: "nonce"), error: .missingPermit, store: store)
            state = try await apply(state, .prepare(next, nonce: "nonce"), store: store)
            state = try await apply(state, .consume(next, nonce: "nonce"), store: store)
            try require(state.sessions.map(\.sequence) == [0, 1] && state.current.revision == 1)
        case .admissionIntegrity:
            state = try await apply(state, .prepare(next, nonce: "nonce"), store: store)
            try await rejectCommand(state, .consume(request(1, admission: Data([0xfe])), nonce: "nonce"), error: .bindingMismatch, store: store)
            state = try await apply(state, .consume(next, nonce: "nonce"), store: store)
            try require(state.current.admission == next.admission && state.current.admissionHash == next.admissionHash)
        case .nonceSingleUse:
            state = try await apply(state, .prepare(next, nonce: "nonce"), store: store)
            state = try await apply(state, .revoke, store: store)
            try await rejectCommand(state, .prepare(next, nonce: "nonce"), error: .nonceAlreadyUsed, store: store)
            let oldPermitRevision = state.revision - 1
            state = try await apply(state, .prepare(next, nonce: "second"), store: store)
            let newPermit = state
            try await rejected(.revisionConflict) {
                _ = try await store.apply(runID: newPermit.runID, expectedRevision: oldPermitRevision, command: .revoke)
            }
            let preserved = try await store.load(runID: state.runID)
            try require(preserved == newPermit)
            state = try await apply(state, .consume(next, nonce: "second"), store: store)
            state = try await apply(state, .finish(.completed), store: store)
            try await rejectCommand(state, .prepare(request(2), nonce: "second"), error: .nonceAlreadyUsed, store: store)
            try require(state.issuedNonceHashes.count == 2)
        case .bindingMismatch:
            let otherID = try BoneRunID("other-run")
            var other = try await store.open(runID: otherID, initial: initial)
            try require(other.runID == otherID && other.current.runID == otherID)
            other = try await apply(other, .finish(.completed), store: store)
            let unknownID = try BoneRunID("unknown-run")
            try await rejected(.missingLedger) { _ = try await store.load(runID: unknownID) }
            try await rejected(.missingLedger) {
                _ = try await store.apply(runID: unknownID, expectedRevision: 1, command: .finish(.completed))
            }
            state = try await apply(state, .prepare(next, nonce: "nonce"), store: store)
            try await rejectCommand(other, .consume(next, nonce: "nonce"), error: .missingPermit, store: store)
            for changed in [try request(1, binding: String(repeating: "b", count: 64)), try request(1, operation: "other"), try request(1, effect: "other")] {
                try await rejectCommand(state, .consume(changed, nonce: "nonce"), error: .bindingMismatch, store: store)
            }
            try await rejectCommand(state, .consume(next, nonce: "other-nonce"), error: .bindingMismatch, store: store)
        case .concurrentConsumption:
            state = try await apply(state, .prepare(next, nonce: "nonce"), store: store)
            let prepared = state
            let successes = try await withThrowingTaskGroup(of: BoneWorkflowSessionLedger?.self) { group in
                for _ in 0..<2 { group.addTask {
                    do { return try await store.apply(runID: prepared.runID, expectedRevision: prepared.revision, command: .consume(next, nonce: "nonce")) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        if error as? BoneWorkflowExecutionSessionError == .revisionConflict { return nil }
                        throw error
                    }
                } }
                var winners: [BoneWorkflowSessionLedger] = []
                for try await result in group { if let result { winners.append(result) } }
                return winners
            }
            try require(successes.count == 1)
            state = successes[0]
            try require(state == prepared.applying(.consume(next, nonce: "nonce")))
            try await rejected(.revisionConflict) {
                _ = try await store.apply(runID: prepared.runID, expectedRevision: prepared.revision, command: .consume(next, nonce: "nonce"))
            }
        }
        let loaded = try await store.load(runID: state.runID)
        try require(loaded == state)
        let reopened = try await store.open(runID: state.runID, initial: initial)
        try require(reopened == state)
        try Task.checkCancellation()
    }
}
