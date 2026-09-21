import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowRunControllerContractSuiteTests: XCTestCase {
    func testMemoryPassesEveryControlPlaneCase() async throws {
        let results = try await BoneWorkflowRunControllerContractSuite().run { _ in
            .init(persistence: BoneInMemoryWorkflowPersistence(), cleanup: {})
        }
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowRunControllerContractCase.allCases)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testIndependentSerializedHostPassesPersistenceAndControlContracts() async throws {
        let persistence = try await BoneWorkflowPersistenceContractSuite().run { _ in
            .init(persistence: SerializedTestHost(), cleanup: {})
        }
        for result in persistence {
            switch result.scenario {
            case .reopenedRead: XCTAssertEqual(result.outcome, .skipped(.reopenAfterClosingPrimary))
            case .independentConnectionConsistency: XCTAssertEqual(result.outcome, .skipped(.independentConnection))
            default: XCTAssertEqual(result.outcome, .passed)
            }
        }
        let control = try await BoneWorkflowRunControllerContractSuite().run { _ in
            .init(persistence: SerializedTestHost(), cleanup: {})
        }
        XCTAssertTrue(control.allSatisfy(\.passed))
    }

    func testContractDetectsMissingStoreFence() async throws {
        let results = try await BoneWorkflowRunControllerContractSuite().run { _ in
            .init(persistence: SerializedTestHost(ignoreFence: true), cleanup: {})
        }
        XCTAssertEqual(results.first { $0.scenario == .pauseResumeFencing }?.failures, [.staleWorkerAccepted])
    }

    func testCleanupAndErrorReportsAreSanitized() async throws {
        let tracker = CleanupTracker()
        let results = try await BoneWorkflowRunControllerContractSuite().run { scenario in
            if scenario == .pendingStart { throw PrivateError() }
            return .init(persistence: SerializedTestHost(), cleanup: {
                await tracker.record()
                throw PrivateError()
            })
        }
        XCTAssertEqual(results.first?.failures, [.fixtureCreationFailed])
        XCTAssertTrue(results.dropFirst().allSatisfy { $0.failures == [.cleanupFailed] })
        let cleaned = await tracker.count
        XCTAssertEqual(cleaned, BoneWorkflowRunControllerContractCase.allCases.count - 1)
        let encoded = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(encoded.contains(PrivateError.secret))
        XCTAssertFalse(encoded.contains("requestLimit"))
    }

    func testParentCancellationStillCleansFixture() async throws {
        let tracker = CleanupTracker()
        let task = Task {
            try await BoneWorkflowRunControllerContractSuite().run { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(persistence: SerializedTestHost(), cleanup: {
                    try Task.checkCancellation()
                    await tracker.record()
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let cleaned = await tracker.count
        XCTAssertEqual(cleaned, 1)
    }
}

private actor CleanupTracker {
    var count = 0
    func record() { count += 1 }
}

private struct PrivateError: Error, CustomStringConvertible {
    static let secret = "/private/test-host.sqlite?token=do-not-report"
    var description: String { Self.secret }
}

/// Independent test Host: own serialized envelope and CAS implementation, no reference-store wrapper.
/// Actor memory only: this is not a production second Host, database, reopen or crash-durability proof.
actor SerializedTestHost: BoneWorkflowPersistence, BoneWorkflowRecoveryScan {
    private struct Envelope: Codable {
        let schema: Int
        let snapshot: BoneWorkflowRunSnapshot
    }
    private var rows: [BoneRunID: Data] = [:]
    private let ignoreFence: Bool
    init(ignoreFence: Bool = false) { self.ignoreFence = ignoreFence }

    // Test-only corruption injection into the actual serialized rows, not fabricated scan results.
    func injectQuarantinedRecord() throws {
        let id = try BoneRunID("broken-\(rows.count)")
        if rows.values.contains(Data([0xff, 0x00])) {
            let plan = try BoneWorkflowPlan(identity: "broken", revision: 1,
                steps: [.init(id: .init("step"), kind: "work", revision: 1)])
            let snapshot = try BoneWorkflowRunSnapshot(
                run: .init(id: id, plan: plan, state: .pending, revision: 2, leaseGeneration: 0),
                checkpoint: .init(descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1),
                    payload: Data("{}".utf8), dataClassification: .safeState, revision: 1))
            rows[id] = try JSONEncoder().encode(Envelope(schema: 1, snapshot: snapshot))
        } else {
            rows[id] = Data([0xff, 0x00])
        }
    }

    func recoverableRunScan() throws -> BoneWorkflowRecoveryScanResult {
        try Task.checkCancellation()
        var trusted: [BoneWorkflowRunSnapshot] = []
        var quarantined = 0
        for (id, bytes) in rows {
            // Catch only row validation/decode errors; a real adapter must keep database I/O outside this catch.
            do {
                let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
                let snapshot = envelope.snapshot
                guard envelope.schema == 1, snapshot.run.id == id, snapshot.run.revision > 0,
                      snapshot.run.revision == snapshot.checkpoint.revision,
                      snapshot.checkpoint.descriptor.workflowIdentity == snapshot.run.plan.identity,
                      snapshot.checkpoint.descriptor.workflowRevision == snapshot.run.plan.revision else {
                    throw BoneWorkflowFailure.corruptedCheckpoint
                }
                switch snapshot.run.state {
                case .completed, .failed, .cancelled: break
                default: trusted.append(snapshot)
                }
            } catch { quarantined += 1 }
        }
        return try .init(trustedRuns: trusted, quarantinedRunCount: quarantined)
    }

    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) throws -> BoneWorkflowRunSnapshot {
        guard rows[run.id] == nil, run.revision == 0, checkpoint.revision == 0 else {
            throw BoneWorkflowFailure.revisionConflict
        }
        return try save(run, checkpoint, revision: 1, generation: run.leaseGeneration)
    }

    func load(runID: BoneRunID) throws -> BoneWorkflowRunSnapshot {
        guard let bytes = rows[runID] else { throw BoneWorkflowFailure.corruptedCheckpoint }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bytes)
        guard envelope.schema == 1 else { throw BoneWorkflowFailure.corruptedCheckpoint }
        return envelope.snapshot
    }

    func commit(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint, expectedRevision: UInt64, leaseGeneration: UInt64) throws -> BoneWorkflowRunSnapshot {
        let current = try load(runID: run.id)
        guard current.run.revision == expectedRevision, current.checkpoint.revision == expectedRevision,
              run.revision == expectedRevision, checkpoint.revision == expectedRevision else {
            throw BoneWorkflowFailure.revisionConflict
        }
        if !ignoreFence {
            guard current.run.leaseGeneration == leaseGeneration, run.leaseGeneration == leaseGeneration else {
                throw BoneWorkflowFailure.leaseConflict
            }
        }
        guard run.plan == current.run.plan else { throw BoneWorkflowFailure.corruptedCheckpoint }
        if run.state != current.run.state { _ = try current.run.state.transitioned(to: run.state) }
        return try save(run, checkpoint, revision: next(expectedRevision), generation: current.run.leaseGeneration)
    }

    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) throws -> BoneWorkflowRunSnapshot {
        let current = try load(runID: runID)
        guard current.run.revision == expectedRevision else { throw BoneWorkflowFailure.revisionConflict }
        return try save(current.run, current.checkpoint, revision: next(expectedRevision), generation: next(current.run.leaseGeneration))
    }

    private func next(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowFailure.revisionConflict }
        return next
    }

    private func save(_ run: BoneWorkflowRunRecord, _ checkpoint: BoneWorkflowCheckpoint, revision: UInt64, generation: UInt64) throws -> BoneWorkflowRunSnapshot {
        guard checkpoint.descriptor.workflowIdentity == run.plan.identity,
              checkpoint.descriptor.workflowRevision == run.plan.revision else { throw BoneWorkflowFailure.corruptedCheckpoint }
        let snapshot = BoneWorkflowRunSnapshot(
            run: .init(id: run.id, plan: run.plan, state: run.state, revision: revision, leaseGeneration: generation),
            checkpoint: try .init(descriptor: checkpoint.descriptor, payload: checkpoint.payload,
                dataClassification: checkpoint.dataClassification, retention: checkpoint.retention, revision: revision))
        let bytes = try JSONEncoder().encode(Envelope(schema: 1, snapshot: snapshot))
        rows[run.id] = bytes
        return snapshot
    }
}
