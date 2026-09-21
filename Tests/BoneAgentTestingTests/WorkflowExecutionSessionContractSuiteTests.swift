import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowExecutionSessionContractSuiteTests: XCTestCase {
    func testMemoryPassesEveryCase() async throws {
        let results = try await BoneWorkflowExecutionSessionContractSuite().run { _ in
            .init(store: BoneInMemoryWorkflowExecutionSessionStore(), cleanup: {})
        }
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowExecutionSessionContractCase.allCases)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }
    func testIndependentEncodedHostPassesEveryCase() async throws {
        let values = try await results()
        XCTAssertTrue(values.allSatisfy(\.passed))
    }
    func testContractDetectsUnsavedReceipt() async throws {
        let results = try await results(.forgetSave)
        XCTAssertTrue(results.allSatisfy { $0.failures == [.snapshotMismatch] })
    }
    func testContractDetectsCrossRunAndNonConsumeCASBugs() async throws {
        let crossRun = try await results(.ignoreRunID)
        XCTAssertEqual(crossRun.first { $0.scenario == .bindingMismatch }?.failures, [.snapshotMismatch])
        let cas = try await results(.ignoreOtherCAS)
        XCTAssertTrue(cas.allSatisfy { $0.failures == [.unexpectedAcceptance] })
    }

    func testBeforeAndAfterConsumeFailurePreserveAtomicLedger() async throws {
        for fault in [SessionBacking.Fault.failBeforeConsume, .failAfterConsume] {
            let store = SessionBacking(fault: fault)
            let initial = try await store.open(runID: .init("run"), initial: request(0))
            let finished = try await store.apply(runID: initial.runID, expectedRevision: initial.revision, command: .finish(.completed))
            let next = try request(1)
            let prepared = try await store.apply(runID: initial.runID, expectedRevision: finished.revision, command: .prepare(next, nonce: "secret-nonce"))
            do {
                _ = try await store.apply(runID: initial.runID, expectedRevision: prepared.revision, command: .consume(next, nonce: "secret-nonce"))
                XCTFail("Failure must propagate")
            } catch { XCTAssertTrue(error is SessionPrivateError) }
            let read = try await store.load(runID: initial.runID)
            XCTAssertEqual(read, fault == .failBeforeConsume ? prepared : try prepared.applying(.consume(next, nonce: "secret-nonce")))
        }
    }
    func testFactoryCleanupAndErrorSanitization() async throws {
        let results = try await BoneWorkflowExecutionSessionContractSuite().run { scenario in
            if scenario == .admissionIntegrity { throw SessionPrivateError() }
            return .init(store: SessionBacking(), cleanup: { throw SessionPrivateError() })
        }
        XCTAssertEqual(results.first?.failures, [.fixtureCreationFailed])
        XCTAssertTrue(results.dropFirst().allSatisfy { $0.failures == [.cleanupFailed] })
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(SessionPrivateError.secret))
        XCTAssertFalse(report.contains("session-run"))
    }
    func testCancelledParentStillCleans() async throws {
        let marker = SessionCleanup()
        let task = Task {
            try await BoneWorkflowExecutionSessionContractSuite().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(store: SessionBacking(), cleanup: {
                    try Task.checkCancellation()
                    await marker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let count = await marker.count
        XCTAssertEqual(count, 1)
    }
    private func request(_ sequence: UInt64) throws -> BoneWorkflowExecutionSession.Request {
        try .init(sequence: sequence, operationID: "op-\(sequence)", effectID: .init("effect-\(sequence)"),
            bindingHash: String(repeating: "a", count: 64), admission: Data([0xff]))
    }
    private func results(_ fault: SessionBacking.Fault = .none) async throws -> [BoneWorkflowExecutionSessionContractObservation] {
        try await BoneWorkflowExecutionSessionContractSuite().run { _ in .init(store: SessionBacking(fault: fault), cleanup: {}) }
    }
}
private struct SessionPrivateError: Error, CustomStringConvertible {
    static let secret = "/private/session.db?token=secret"
    var description: String { Self.secret }
}
private actor SessionCleanup {
    var count = 0
    func record() { count += 1 }
}
/// Own encoded rows and transaction boundary, no reference Store wrapper. Actor simulation, not a real DB.
private actor SessionBacking: BoneWorkflowExecutionSessionStore {
    enum Fault: Sendable { case none, forgetSave, failBeforeConsume, failAfterConsume, ignoreOtherCAS, ignoreRunID }
    let fault: Fault
    private var rows: [BoneRunID: Data] = [:]
    init(fault: Fault = .none) { self.fault = fault }
    func open(runID: BoneRunID, initial: BoneWorkflowExecutionSession.Request) throws -> BoneWorkflowSessionLedger {
        try Task.checkCancellation()
        if fault == .ignoreRunID, let first = rows.values.first {
            return try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: first)
        }
        if rows[runID] != nil {
            let old = try load(runID: runID)
            guard old.initialRequest == initial else { throw BoneWorkflowExecutionSessionError.bindingMismatch }
            return old
        }
        let value = try BoneWorkflowSessionLedger(runID: runID, initial: initial)
        rows[runID] = try JSONEncoder().encode(value)
        return value
    }
    func load(runID: BoneRunID) throws -> BoneWorkflowSessionLedger {
        try Task.checkCancellation()
        guard let row = rows[runID] else { throw BoneWorkflowExecutionSessionError.missingLedger }
        let state = try JSONDecoder().decode(BoneWorkflowSessionLedger.self, from: row)
        guard state.runID == runID else { throw BoneWorkflowExecutionSessionError.bindingMismatch }
        return state
    }
    func apply(runID: BoneRunID, expectedRevision: UInt64, command: BoneWorkflowSessionLedger.Command) throws -> BoneWorkflowSessionLedger {
        let old = try load(runID: runID)
        var enforceCAS = true
        if fault == .ignoreOtherCAS {
            if case .consume = command {} else { enforceCAS = false }
        }
        guard !enforceCAS || old.revision == expectedRevision else { throw BoneWorkflowExecutionSessionError.revisionConflict }
        let value = try old.applying(command)
        if fault == .failBeforeConsume, case .consume = command { throw SessionPrivateError() }
        if fault != .forgetSave { rows[runID] = try JSONEncoder().encode(value) }
        if fault == .failAfterConsume, case .consume = command { throw SessionPrivateError() }
        return value
    }
}
