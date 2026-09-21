import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowWorkLedgerContractSuiteTests: XCTestCase {
    func testMemoryPassesAllCases() async throws {
        let results = try await BoneWorkflowWorkLedgerContractSuite().run { _ in
            .init(store: BoneInMemoryWorkflowWorkLedgerStore(), cleanup: {})
        }
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowWorkLedgerContractCase.allCases)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }
    func testIndependentJournalHostPassesAllCases() async throws {
        let results = try await run()
        XCTAssertTrue(results.allSatisfy(\.passed))
    }
    func testDetectsFakeSavedReceipt() async throws {
        let results = try await run(.forgetSave)
        XCTAssertTrue(results.allSatisfy { $0.failures == [.snapshotMismatch] })
    }
    func testDetectsMissingRevisionCAS() async throws {
        let results = try await run(.ignoreRevision)
        XCTAssertEqual(results.first { $0.scenario == .pageCAS }?.failures, [.unexpectedRejection])
    }
    func testContractDetectsMissingLeaseCASAndCrossUnitCAS() async throws {
        let lease = try await run(.ignoreLeaseRevision)
        XCTAssertEqual(lease.first { $0.scenario == .generationFencing }?.failures, [.unexpectedAcceptance])
        let aggregate = try await run(.ignoreRevision)
        XCTAssertEqual(aggregate.first { $0.scenario == .aggregateCAS }?.failures, [.unexpectedAcceptance])
    }

    func testConcurrentJournalWritersHaveOneWinner() async throws {
        let store = JournalWorkStore()
        let initial = try await store.open(runID: .init("run"), leaseGeneration: 1, units: [.init(id: "unit", payload: Data())])
        let count = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask {
                do {
                    _ = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: .reserve(unitID: "unit", page: 0))
                    return true
                } catch { XCTAssertEqual(error as? BoneWorkflowWorkLedgerError, .revisionConflict); return false }
            } }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(count, 1)
    }
    func testSplitCommitUnknownPreservesWholeOldOrWholeNewJournal() async throws {
        for fault in [JournalWorkStore.Fault.failBeforeSave, .failAfterSave] {
            let store = JournalWorkStore(fault: fault)
            let initial = try await store.open(runID: .init("run"), leaseGeneration: 1, units: [.init(id: "unit", payload: Data())])
            let command = try BoneWorkflowWorkLedger.Command.split(unitID: "unit", children: [
                .init(id: "a", payload: Data([1])), .init(id: "b", payload: Data([2]))
            ])
            do {
                _ = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: command)
                XCTFail("Injected commit failure must escape")
            } catch { XCTAssertTrue(error is LedgerPrivateError) }
            let stored = try await store.load(runID: initial.runID)
            if fault == .failBeforeSave { XCTAssertEqual(stored, initial) }
            else {
                XCTAssertEqual(stored, try initial.applying(command, leaseGeneration: 1))
                do {
                    _ = try await store.apply(runID: initial.runID, expectedRevision: 1, leaseGeneration: 1, command: command)
                    XCTFail("Old revision cannot split twice")
                } catch { XCTAssertEqual(error as? BoneWorkflowWorkLedgerError, .revisionConflict) }
            }
        }
    }

    func testCancellationAndCleanup() async throws {
        let tracker = LedgerCleanup()
        let task = Task {
            try await BoneWorkflowWorkLedgerContractSuite().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(store: JournalWorkStore(), cleanup: {
                    try Task.checkCancellation()
                    await tracker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let count = await tracker.count
        XCTAssertEqual(count, 1)
    }
    func testSanitizedFactoryAndCleanupFailures() async throws {
        let results = try await BoneWorkflowWorkLedgerContractSuite().run { scenario in
            if scenario == .pageCAS { throw LedgerPrivateError() }
            return .init(store: JournalWorkStore(), cleanup: { throw LedgerPrivateError() })
        }
        XCTAssertEqual(results.first?.failures, [.fixtureCreationFailed])
        XCTAssertTrue(results.dropFirst().allSatisfy { $0.failures == [.cleanupFailed] })
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(LedgerPrivateError.secret))
        XCTAssertFalse(report.contains("ledger-run"))
    }
    private func run(_ fault: JournalWorkStore.Fault = .none) async throws -> [BoneWorkflowWorkLedgerContractObservation] {
        try await BoneWorkflowWorkLedgerContractSuite().run { _ in .init(store: JournalWorkStore(fault: fault), cleanup: {}) }
    }
}
private struct LedgerPrivateError: Error, CustomStringConvertible {
    static let secret = "/private/work.db?token=secret"
    var description: String { Self.secret }
}
private actor LedgerCleanup {
    var count = 0
    func record() { count += 1 }
}

/// Independent encoded command journal; every read replays validated transitions, no memory Store wrapper.
/// Actor memory only, not a production event log or physical durability proof.
private actor JournalWorkStore: BoneWorkflowWorkReconciliationStore {
    enum Fault: Sendable { case none, forgetSave, ignoreRevision, failBeforeSave, failAfterSave, ignoreLeaseRevision, reconcileBeforeSave, reconcileAfterSave, reconcileIgnoreRevision, reconcileForgetSave }
    private struct Journal: Codable {
        let runID: BoneRunID
        let initialGeneration: UInt64
        let seeds: [BoneWorkflowWorkLedger.Seed]
        var events: [Event]
    }
    private enum Event: Codable {
        case command(BoneWorkflowWorkLedger.Command, UInt64)
        case lease(UInt64, UInt64)
        case reconciliation(BoneWorkflowWorkLedger.Reconciliation)
    }
    private var rows: [BoneRunID: Data] = [:]
    private let fault: Fault
    init(fault: Fault = .none) { self.fault = fault }
    func open(runID: BoneRunID, leaseGeneration: UInt64, units: [BoneWorkflowWorkLedger.Seed]) throws -> BoneWorkflowWorkLedger {
        try Task.checkCancellation()
        if rows[runID] != nil {
            let current = try load(runID: runID)
            guard current.preparedUnits == units else { throw BoneWorkflowWorkLedgerError.planMismatch }
            guard current.leaseGeneration == leaseGeneration else { throw BoneWorkflowWorkLedgerError.leaseConflict }
            return current
        }
        let state = try BoneWorkflowWorkLedger(runID: runID, leaseGeneration: leaseGeneration, units: units)
        rows[runID] = try JSONEncoder().encode(Journal(runID: runID, initialGeneration: leaseGeneration, seeds: units, events: []))
        return state
    }
    private func journal(_ id: BoneRunID) throws -> Journal {
        guard let data = rows[id] else { throw BoneWorkflowWorkLedgerError.missingLedger }
        return try JSONDecoder().decode(Journal.self, from: data)
    }
    func load(runID: BoneRunID) throws -> BoneWorkflowWorkLedger {
        try Task.checkCancellation()
        let log = try journal(runID)
        var state = try BoneWorkflowWorkLedger(runID: log.runID, leaseGeneration: log.initialGeneration, units: log.seeds)
        for event in log.events {
            switch event {
            case .command(let command, let generation): state = try state.applying(command, leaseGeneration: generation)
            case .reconciliation(let request): state = try state.reconciling(request)
            case .lease(let old, let new): state = try state.advancingLease(expectedGeneration: old, newGeneration: new)
            }
        }
        return state
    }
    func apply(runID: BoneRunID, expectedRevision: UInt64, leaseGeneration: UInt64, command: BoneWorkflowWorkLedger.Command) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: runID)
        guard fault == .ignoreRevision || current.revision == expectedRevision else { throw BoneWorkflowWorkLedgerError.revisionConflict }
        let next = try current.applying(command, leaseGeneration: leaseGeneration)
        var log = try journal(runID)
        log.events.append(.command(command, leaseGeneration))
        if fault == .failBeforeSave { throw LedgerPrivateError() }
        if fault != .forgetSave { rows[runID] = try JSONEncoder().encode(log) }
        if fault == .failAfterSave { throw LedgerPrivateError() }
        return next
    }
    func reconcile(_ request: BoneWorkflowWorkLedger.Reconciliation) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: request.runID)
        let effective: BoneWorkflowWorkLedger.Reconciliation
        if fault == .reconcileIgnoreRevision {
            effective = try .init(runID: request.runID, unitID: request.unitID, page: request.page,
                sourceGeneration: request.sourceGeneration, resolvingGeneration: request.resolvingGeneration,
                expectedRevision: current.revision, evidenceID: request.evidenceID, outcome: request.outcome)
        } else { effective = request }
        let next = try current.reconciling(effective)
        var log = try journal(request.runID)
        log.events.append(.reconciliation(effective))
        if fault == .reconcileBeforeSave { throw LedgerPrivateError() }
        if fault != .reconcileForgetSave { rows[request.runID] = try JSONEncoder().encode(log) }
        if fault == .reconcileAfterSave { throw LedgerPrivateError() }
        return next
    }
    func advanceLease(runID: BoneRunID, expectedRevision: UInt64, expectedGeneration: UInt64, newGeneration: UInt64) throws -> BoneWorkflowWorkLedger {
        let current = try load(runID: runID)
        guard fault == .ignoreLeaseRevision || current.revision == expectedRevision else { throw BoneWorkflowWorkLedgerError.revisionConflict }
        let next = try current.advancingLease(expectedGeneration: expectedGeneration, newGeneration: newGeneration)
        var log = try journal(runID)
        log.events.append(.lease(expectedGeneration, newGeneration))
        rows[runID] = try JSONEncoder().encode(log)
        return next
    }
}

final class WorkflowWorkReconciliationContractSuiteTests: XCTestCase {
    func testMemoryAndIndependentJournalPassAllCases() async throws {
        let memory = try await BoneWorkflowWorkReconciliationContractSuite().run { _ in
            .init(store: BoneInMemoryWorkflowWorkLedgerStore(), cleanup: {})
        }
        let journal = try await results()
        XCTAssertEqual(memory.map(\.scenario), BoneWorkflowWorkReconciliationContractCase.allCases)
        XCTAssertTrue(memory.allSatisfy(\.passed))
        XCTAssertTrue(journal.allSatisfy(\.passed))
    }
    func testMutantsDetected() async throws {
        let cas = try await results(.reconcileIgnoreRevision)
        XCTAssertTrue(cas.allSatisfy { !$0.passed })
        XCTAssertEqual(cas.first?.failures, [.unexpectedAcceptance])
        let missing = try await results(.reconcileForgetSave)
        XCTAssertTrue(missing.allSatisfy { !$0.passed })
        XCTAssertEqual(missing.first?.failures, [.snapshotMismatch])
    }
    func testUnknownCommitBeforeOrAfterWriteReplaysWholeState() async throws {
        for committed in [false, true] {
            for fault in [JournalWorkStore.Fault.reconcileBeforeSave, .reconcileAfterSave] {
                let store = JournalWorkStore(fault: fault)
                let id = try BoneRunID("run")
                var state = try await store.open(runID: id, leaseGeneration: 1, units: [.init(id: "unit", payload: Data())])
                state = try await store.apply(runID: id, expectedRevision: state.revision, leaseGeneration: 1,
                    command: .reserve(unitID: "unit", page: 0))
                if committed {
                    state = try await store.apply(runID: id, expectedRevision: state.revision, leaseGeneration: 1,
                        command: .dispatch(unitID: "unit", page: 0))
                }
                state = try await store.advanceLease(runID: id, expectedRevision: state.revision, expectedGeneration: 1, newGeneration: 2)
                let request = try BoneWorkflowWorkLedger.Reconciliation(runID: id, unitID: "unit", page: 0, sourceGeneration: 1,
                    resolvingGeneration: 2, expectedRevision: state.revision, evidenceID: "evidence",
                    outcome: committed ? .committed(response: Data([1]), cursor: Data([2]), artifact: Data([3]), completed: false) : .knownFailure)
                do { _ = try await store.reconcile(request); XCTFail("Injected error must escape") }
                catch { XCTAssertTrue(error is LedgerPrivateError) }
                let read = try await store.load(runID: id)
                XCTAssertEqual(read, fault == .reconcileBeforeSave ? state : try state.reconciling(request))
                if fault == .reconcileAfterSave {
                    do { _ = try await store.reconcile(request); XCTFail("Stale receipt cannot apply twice") }
                    catch { XCTAssertEqual(error as? BoneWorkflowWorkLedgerError, .revisionConflict) }
                }
            }
        }
    }
    func testSanitizedFailuresAndCleanup() async throws {
        let values = try await BoneWorkflowWorkReconciliationContractSuite().run { scenario in
            if scenario == .committedRecovery { throw LedgerPrivateError() }
            return .init(store: JournalWorkStore(), cleanup: { throw LedgerPrivateError() })
        }
        XCTAssertEqual(values.first?.failures, [.fixtureCreationFailed])
        XCTAssertTrue(values.dropFirst().allSatisfy { $0.failures == [.cleanupFailed] })
        let text = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        XCTAssertFalse(text.contains(LedgerPrivateError.secret))
        XCTAssertFalse(text.contains("host-evidence"))
    }
    func testCancelledParentStillCleans() async throws {
        let tracker = LedgerCleanup()
        let task = Task {
            try await BoneWorkflowWorkReconciliationContractSuite().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(store: JournalWorkStore(), cleanup: {
                    try Task.checkCancellation()
                    await tracker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Wrong error") }
        let count = await tracker.count
        XCTAssertEqual(count, 1)
    }
    private func results(_ fault: JournalWorkStore.Fault = .none) async throws -> [BoneWorkflowWorkReconciliationContractObservation] {
        try await BoneWorkflowWorkReconciliationContractSuite().run { _ in .init(store: JournalWorkStore(fault: fault), cleanup: {}) }
    }
}
