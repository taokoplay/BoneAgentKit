import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowRunBudgetContractSuiteTests: XCTestCase {
    func testMemoryPassesAllExceptRealReopen() async throws {
        let results = try await BoneWorkflowRunBudgetContractSuite().run { _ in
            .init(store: BoneInMemoryWorkflowRunBudgetStore(), cleanup: {})
        }
        for result in results {
            XCTAssertEqual(result.outcome, result.scenario == .reopenPreservesBudget ? .skippedReopen : .passed)
        }
    }

    func testSerializedBackingWithNewConnectionPassesAll() async throws {
        let results = try await run()
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowRunBudgetContractCase.allCases)
        XCTAssertTrue(results.allSatisfy { $0.outcome == .passed })
    }

    func testDetectsResetOnReopen() async throws {
        let results = try await run(.resetOnOpen)
        XCTAssertEqual(results.first { $0.scenario == .reopenPreservesBudget }?.outcome, .failed([.snapshotMismatch]))
    }

    func testDetectsRejectedReservationNotPersisted() async throws {
        let results = try await run(.forgetRejected)
        XCTAssertEqual(results.first { $0.scenario == .finalReserve }?.outcome, .failed([.snapshotMismatch]))
    }

    func testContractDetectsIgnoredPolicyFields() async throws {
        let results = try await run(.ignorePolicyFields)
        XCTAssertEqual(results.first { $0.scenario == .policyDrift }?.outcome, .failed([.unexpectedRejection]))
    }

    func testBeforeAndAfterWriteFailuresDoNotJustifyRefundOrBlindRetry() async throws {
        for fault in [BudgetBacking.Fault.failBeforeWrite, .failAfterWrite] {
            let backing = BudgetBacking(fault: fault)
            let store = BudgetConnection(backing: backing)
            let clock = BoneWorkflowRunBudget.Clock(wallTime: 1000, uptime: 10, bootID: "boot")
            let initial = try await store.open(runID: .init("fault-run"),
                policy: .init(versionTag: "v1", requestLimit: 3, reservedFinalRequests: 1, durationSeconds: 100), now: clock)
            do {
                _ = try await store.reserve(runID: initial.runID, expectedRevision: initial.revision, phase: .ordinary, now: clock)
                XCTFail("Injected failure must escape")
            } catch { XCTAssertTrue(error is BudgetPrivateError) }
            let recovered = try await store.load(runID: initial.runID)
            if fault == .failBeforeWrite { XCTAssertEqual(recovered, initial) }
            else {
                XCTAssertEqual(recovered.usedRequests, 1)
                XCTAssertEqual(recovered.attemptedRequests, 1)
                XCTAssertEqual(recovered.revision, 2)
                do {
                    _ = try await store.reserve(runID: initial.runID, expectedRevision: initial.revision, phase: .ordinary, now: clock)
                    XCTFail("Old revision cannot reserve twice")
                } catch { XCTAssertEqual(error as? BoneWorkflowRunBudgetError, .revisionConflict) }
            }
        }
    }

    func testCleanupAndErrorsAreSanitized() async throws {
        let tracker = BudgetCleanupTracker()
        let results = try await BoneWorkflowRunBudgetContractSuite().run { scenario in
            if scenario == .requestLimit { throw BudgetPrivateError() }
            return .init(store: BoneInMemoryWorkflowRunBudgetStore(), cleanup: {
                await tracker.record()
                throw BudgetPrivateError()
            })
        }
        XCTAssertEqual(results.first?.outcome, .failed([.fixtureCreationFailed]))
        let count = await tracker.count
        XCTAssertEqual(count, BoneWorkflowRunBudgetContractCase.allCases.count - 1)
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(BudgetPrivateError.secret))
        XCTAssertFalse(report.contains("budget-run"))
    }

    func testParentCancellationStillCleans() async throws {
        let tracker = BudgetCleanupTracker()
        let task = Task {
            try await BoneWorkflowRunBudgetContractSuite().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(store: BoneInMemoryWorkflowRunBudgetStore(), cleanup: {
                    try Task.checkCancellation()
                    await tracker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let count = await tracker.count
        XCTAssertEqual(count, 1)
    }

    private func run(_ fault: BudgetBacking.Fault = .none) async throws -> [BoneWorkflowRunBudgetContractObservation] {
        try await BoneWorkflowRunBudgetContractSuite().run { _ in
            let backing = BudgetBacking(fault: fault)
            let primary = BudgetConnection(backing: backing)
            return .init(store: primary, reopen: {
                await primary.close()
                return BudgetConnection(backing: backing)
            }, cleanup: {})
        }
    }
}

private struct BudgetPrivateError: Error, CustomStringConvertible {
    static let secret = "/private/budget.db?token=secret"
    var description: String { Self.secret }
}
private actor BudgetCleanupTracker {
    var count = 0
    func record() { count += 1 }
}

/// Separate Host storage adapter: own encoded rows, atomic transaction actor, explicit connection lifecycle.
/// Uses public pure budget transition, not the memory Store. Reopen here is only an API-level simulation.
private actor BudgetBacking {
    enum Fault: Sendable { case none, resetOnOpen, forgetRejected, ignorePolicyFields, failBeforeWrite, failAfterWrite }
    let fault: Fault
    private var rows: [BoneRunID: Data] = [:]
    init(fault: Fault) { self.fault = fault }
    func open(runID: BoneRunID, policy: BoneWorkflowRunBudget.Policy, now: BoneWorkflowRunBudget.Clock) throws -> BoneWorkflowRunBudget {
        if let data = rows[runID], fault != .resetOnOpen {
            let value = try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: data)
            if fault == .ignorePolicyFields {
                guard value.policy.versionTag == policy.versionTag && value.policy.requestLimit == policy.requestLimit else {
                    throw BoneWorkflowRunBudgetError.policyMismatch
                }
            } else {
                guard value.policy == policy else { throw BoneWorkflowRunBudgetError.policyMismatch }
            }
            return value
        }
        let value = try BoneWorkflowRunBudget(runID: runID, policy: policy, started: now)
        rows[runID] = try JSONEncoder().encode(value)
        return value
    }
    func load(runID: BoneRunID) throws -> BoneWorkflowRunBudget {
        guard let data = rows[runID] else { throw BoneWorkflowRunBudgetError.missingBudget }
        return try JSONDecoder().decode(BoneWorkflowRunBudget.self, from: data)
    }
    func reserve(runID: BoneRunID, expectedRevision: UInt64, phase: BoneWorkflowRunBudget.Phase,
                 now: BoneWorkflowRunBudget.Clock) throws -> BoneWorkflowRunBudget.Reservation {
        let old = try load(runID: runID)
        guard old.revision == expectedRevision else { throw BoneWorkflowRunBudgetError.revisionConflict }
        let result = try old.reserving(phase: phase, now: now)
        if fault == .forgetRejected, case .rejected = result.decision { return result }
        let encoded = try JSONEncoder().encode(result.snapshot)
        if fault == .failBeforeWrite { throw BudgetPrivateError() }
        rows[runID] = encoded
        if fault == .failAfterWrite { throw BudgetPrivateError() }
        return result
    }
}
private actor BudgetConnection: BoneWorkflowRunBudgetStore {
    let backing: BudgetBacking
    private var closed = false
    init(backing: BudgetBacking) { self.backing = backing }
    func close() { closed = true }
    private func check() throws {
        try Task.checkCancellation()
        if closed { throw BudgetPrivateError() }
    }
    func open(runID: BoneRunID, policy: BoneWorkflowRunBudget.Policy, now: BoneWorkflowRunBudget.Clock) async throws -> BoneWorkflowRunBudget {
        try check()
        return try await backing.open(runID: runID, policy: policy, now: now)
    }
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunBudget {
        try check()
        return try await backing.load(runID: runID)
    }
    func reserve(runID: BoneRunID, expectedRevision: UInt64, phase: BoneWorkflowRunBudget.Phase,
                 now: BoneWorkflowRunBudget.Clock) async throws -> BoneWorkflowRunBudget.Reservation {
        try check()
        return try await backing.reserve(runID: runID, expectedRevision: expectedRevision, phase: phase, now: now)
    }
}
