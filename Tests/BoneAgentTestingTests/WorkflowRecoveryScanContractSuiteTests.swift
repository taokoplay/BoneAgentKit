import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowRecoveryScanContractSuiteTests: XCTestCase {
    func testMemoryExplicitlySkipsUnavailableCorruptionInjection() async throws {
        let results = try await BoneWorkflowRecoveryScanContractSuite().run { _ in
            let store = BoneInMemoryWorkflowPersistence()
            return .init(persistence: store, recoveryScan: store, cleanup: {})
        }
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowRecoveryScanContractCase.allCases)
        XCTAssertEqual(results.map(\.outcome), [.passed, .passed, .passed, .skipped(.injectQuarantinedRecord)])
    }

    func testSerializedHostIsolatesMalformedAndMismatchedRows() async throws {
        let results = try await run()
        XCTAssertEqual(results.map(\.outcome), Array(repeating: .passed, count: 4))
    }

    func testOnlyCorruptRowsProduceStableCountAndNoTrustedRuns() async throws {
        let store = SerializedTestHost()
        try await store.injectQuarantinedRecord()
        try await store.injectQuarantinedRecord()
        for _ in 0..<2 {
            let result = try await store.recoverableRunScan()
            XCTAssertTrue(result.trustedRuns.isEmpty)
            XCTAssertEqual(result.quarantinedRunCount, 2)
        }
    }

    func testInfrastructureFailureIsNotConvertedToQuarantineSuccess() async throws {
        let results = try await run(.infrastructureFailure)
        XCTAssertTrue(results.allSatisfy { $0.outcome == .failed([.operationFailed]) })
    }

    func testParentCancellationDoesNotPreventCleanup() async throws {
        let tracker = ScanCleanupTracker()
        let task = Task {
            try await BoneWorkflowRecoveryScanContractSuite().run { _ in
                let store = BoneInMemoryWorkflowPersistence()
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(persistence: store, recoveryScan: store, cleanup: {
                    try Task.checkCancellation()
                    await tracker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let cleaned = await tracker.count
        XCTAssertEqual(cleaned, 1)
    }

    func testDetectsDroppedQuarantineCount() async throws {
        let results = try await run(.dropCount)
        XCTAssertEqual(outcome(.quarantinedRecordIsolation, results), .failed([.quarantineCountMismatch]))
    }

    func testDetectsCumulativeRatherThanSnapshotCount() async throws {
        let results = try await run(.cumulativeCount)
        XCTAssertEqual(outcome(.quarantinedRecordIsolation, results), .failed([.quarantineCountMismatch]))
    }

    func testDetectsMissingCandidateWithoutChangingQuarantineCount() async throws {
        let results = try await run(.dropCandidate)
        XCTAssertEqual(outcome(.recoveryCandidates, results), .failed([.snapshotMismatch]))
    }

    func testDetectsScanMutatingRunGeneration() async throws {
        let results = try await run(.mutate)
        XCTAssertEqual(outcome(.readOnlyScan, results), .failed([.snapshotMismatch]))
    }

    func testRowCorruptionMustNotFailWholeScanOrLeakError() async throws {
        let results = try await run(.failOnCorruption)
        XCTAssertEqual(outcome(.quarantinedRecordIsolation, results), .failed([.operationFailed]))
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(ScanPrivateError.secret))
        XCTAssertFalse(report.contains("used"))
        XCTAssertFalse(report.contains("scan-0"))
    }

    func testCancellationPropagatesAfterCleanup() async throws {
        let tracker = ScanCleanupTracker()
        do {
            _ = try await BoneWorkflowRecoveryScanContractSuite().run { _ in
                let store = SerializedTestHost()
                return .init(persistence: store, recoveryScan: ScanFaultAdapter(store, fault: .cancel),
                    cleanup: { await tracker.record() })
            }
            XCTFail("Cancellation must escape")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let cleaned = await tracker.count
        XCTAssertEqual(cleaned, 1)
    }

    func testCleanupFailurePreservesProbeFailureAndCleansAllFixtures() async throws {
        let tracker = ScanCleanupTracker()
        let results = try await BoneWorkflowRecoveryScanContractSuite().run { _ in
            let store = SerializedTestHost()
            return .init(persistence: store, recoveryScan: ScanFaultAdapter(store, fault: .dropCount),
                injectQuarantinedRecord: { try await store.injectQuarantinedRecord() }, cleanup: {
                    await tracker.record()
                    throw ScanPrivateError()
                })
        }
        XCTAssertEqual(outcome(.quarantinedRecordIsolation, results), .failed([.quarantineCountMismatch, .cleanupFailed]))
        let cleaned = await tracker.count
        XCTAssertEqual(cleaned, 4)
    }

    func testFactoryFailureSanitizedAndRemainingCasesContinue() async throws {
        let results = try await BoneWorkflowRecoveryScanContractSuite().run { scenario in
            if scenario == .emptyScan { throw ScanPrivateError() }
            let store = BoneInMemoryWorkflowPersistence()
            return .init(persistence: store, recoveryScan: store, cleanup: {})
        }
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(outcome(.emptyScan, results), .failed([.fixtureCreationFailed]))
        XCTAssertEqual(outcome(.recoveryCandidates, results), .passed)
    }

    private func run(_ fault: ScanFaultAdapter.Fault = .none) async throws -> [BoneWorkflowRecoveryScanContractObservation] {
        try await BoneWorkflowRecoveryScanContractSuite().run { _ in
            let store = SerializedTestHost()
            return .init(persistence: store, recoveryScan: ScanFaultAdapter(store, fault: fault),
                injectQuarantinedRecord: { try await store.injectQuarantinedRecord() }, cleanup: {})
        }
    }

    private func outcome(_ scenario: BoneWorkflowRecoveryScanContractCase, _ results: [BoneWorkflowRecoveryScanContractObservation]) -> BoneWorkflowRecoveryScanContractOutcome? {
        results.first { $0.scenario == scenario }?.outcome
    }
}

private struct ScanPrivateError: Error, CustomStringConvertible {
    static let secret = "/private/scan-store.sqlite?token=do-not-report"
    var description: String { Self.secret }
}

private actor ScanCleanupTracker {
    var count = 0
    func record() { count += 1 }
}

private actor ScanFaultAdapter: BoneWorkflowRecoveryScan {
    enum Fault: Sendable { case none, dropCount, cumulativeCount, dropCandidate, mutate, failOnCorruption, cancel, infrastructureFailure }
    private let store: SerializedTestHost
    private let fault: Fault
    private var cumulative = 0
    init(_ store: SerializedTestHost, fault: Fault) { self.store = store; self.fault = fault }

    func recoverableRunScan() async throws -> BoneWorkflowRecoveryScanResult {
        if fault == .cancel { throw CancellationError() }
        if fault == .infrastructureFailure { throw ScanPrivateError() }
        let result = try await store.recoverableRunScan()
        if fault == .failOnCorruption && result.quarantinedRunCount > 0 { throw ScanPrivateError() }
        if fault == .mutate, let first = result.trustedRuns.first {
            _ = try await store.acquireLease(runID: first.run.id, expectedRevision: first.run.revision)
        }
        cumulative += result.quarantinedRunCount
        return try .init(trustedRuns: fault == .dropCandidate ? Array(result.trustedRuns.dropFirst()) : result.trustedRuns,
            quarantinedRunCount: fault == .dropCount ? 0 : fault == .cumulativeCount ? cumulative : result.quarantinedRunCount)
    }
}
