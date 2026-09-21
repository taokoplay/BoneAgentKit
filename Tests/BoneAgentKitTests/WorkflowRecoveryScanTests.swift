import Foundation
import XCTest
import BoneAgentKit

final class WorkflowRecoveryScanTests: XCTestCase {
    func testEmptyMemoryScan() async throws {
        let result = try await BoneInMemoryWorkflowPersistence().recoverableRunScan()
        XCTAssertEqual(result.trustedRuns, [])
        XCTAssertEqual(result.quarantinedRunCount, 0)
    }

    func testCandidatesIncludeRecoveryRequiredButNotFinishedRuns() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let states: [BoneWorkflowRunState] = [.pending, .running, .pausing, .paused, .waitingForAuthorization,
            .cancelling, .recoveryRequired, .completed, .failed, .cancelled]
        var expected: [BoneWorkflowRunSnapshot] = []
        for (index, state) in states.enumerated() {
            let input = try snapshot(id: "run-\(index)", state: state, revision: 0)
            let saved = try await store.create(run: input.run, checkpoint: input.checkpoint)
            if index < 7 { expected.append(saved) }
        }
        let first = try await store.recoverableRunScan()
        let second = try await store.recoverableRunScan()
        XCTAssertEqual(Set(first.trustedRuns.map(\.run.id)), Set(expected.map(\.run.id)))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.quarantinedRunCount, 0)
        for saved in expected {
            let loaded = try await store.load(runID: saved.run.id)
            XCTAssertEqual(loaded, saved)
        }
    }

    func testResultRejectsInvalidCountsDuplicatesAndFinishedRuns() throws {
        let valid = try snapshot()
        XCTAssertThrowsError(try BoneWorkflowRecoveryScanResult(trustedRuns: [], quarantinedRunCount: -1))
        XCTAssertThrowsError(try BoneWorkflowRecoveryScanResult(trustedRuns: [valid, valid], quarantinedRunCount: 0))
        for state in [BoneWorkflowRunState.completed, .failed, .cancelled] {
            XCTAssertThrowsError(try BoneWorkflowRecoveryScanResult(trustedRuns: [snapshot(state: state)], quarantinedRunCount: 0))
        }
    }

    func testResultRejectsBrokenSnapshotEnvelope() throws {
        let valid = try snapshot()
        let mismatched = BoneWorkflowRunSnapshot(run: valid.run, checkpoint: try .init(
            descriptor: valid.checkpoint.descriptor, payload: valid.checkpoint.payload,
            dataClassification: .safeState, revision: 2))
        let wrongPlan = BoneWorkflowRunSnapshot(run: valid.run, checkpoint: try .init(
            descriptor: .init(formatVersion: 1, workflowIdentity: "other", workflowRevision: 1),
            payload: valid.checkpoint.payload, dataClassification: .safeState, revision: 1))
        for invalid in [mismatched, wrongPlan, try snapshot(revision: 0)] {
            XCTAssertThrowsError(try BoneWorkflowRecoveryScanResult(trustedRuns: [invalid], quarantinedRunCount: 0)) {
                XCTAssertEqual($0 as? BoneWorkflowFailure, .corruptedCheckpoint)
            }
        }
    }

    func testValidQuarantineOnlyResult() throws {
        let result = try BoneWorkflowRecoveryScanResult(trustedRuns: [], quarantinedRunCount: 2)
        XCTAssertTrue(result.trustedRuns.isEmpty)
        XCTAssertEqual(result.quarantinedRunCount, 2)
    }

    private func snapshot(id: String = "run", state: BoneWorkflowRunState = .pending, revision: UInt64 = 1) throws -> BoneWorkflowRunSnapshot {
        let plan = try BoneWorkflowPlan(identity: "scan-test", revision: 1,
            steps: [.init(id: .init("step"), kind: "work", revision: 1)])
        return try .init(run: .init(id: .init(id), plan: plan, state: state, revision: revision, leaseGeneration: 0),
            checkpoint: .init(descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1),
                payload: Data("{\"used\":3}".utf8), dataClassification: .safeState, revision: revision))
    }
}
