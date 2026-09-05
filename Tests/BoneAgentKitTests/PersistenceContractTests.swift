import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

/// SDK in-memory contract only: no wall-clock lease expiry or disk durability is implied.
final class PersistenceContractTests: XCTestCase {
    private static func seed(_ store: BoneInMemoryWorkflowPersistence) async throws -> BoneWorkflowRunSnapshot {
        let plan = try BoneWorkflowPlan(identity: "contract", revision: 1, steps: [.init(id: .init("step"), kind: "test", revision: 1)])
        return try await store.create(run: .init(id: .init("run"), plan: plan, state: .pending, revision: 0, leaseGeneration: 1),
            checkpoint: .init(descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1), payload: Data("{\"value\":0}".utf8), dataClassification: .safeState))
    }

    private static func change(_ snapshot: BoneWorkflowRunSnapshot, state: BoneWorkflowRunState = .running, generation: UInt64? = nil, identity: String? = nil) throws -> BoneWorkflowRunSnapshot {
        .init(run: .init(id: snapshot.run.id, plan: snapshot.run.plan, state: state, revision: snapshot.run.revision, leaseGeneration: generation ?? snapshot.run.leaseGeneration),
              checkpoint: try .init(descriptor: .init(formatVersion: 1, workflowIdentity: identity ?? snapshot.run.plan.identity, workflowRevision: 1), payload: Data("{\"value\":1}".utf8), dataClassification: .safeState, revision: snapshot.checkpoint.revision))
    }

    func testCrashBoundariesExposeWholeOldOrWholeNewSnapshot() async throws {
        _ = try await BoneCrashBoundaryHarness().run { boundary in
            let store = BoneInMemoryWorkflowPersistence()
            let old = try await Self.seed(store)
            let next = try Self.change(old)
            if boundary != .beforePersistenceCommit {
                _ = try await store.commit(run: next.run, checkpoint: next.checkpoint, expectedRevision: 1, leaseGeneration: 1)
            }
            let recovered = try await store.load(runID: old.run.id)
            if boundary == .beforePersistenceCommit { XCTAssertEqual(recovered, old) }
            else {
                XCTAssertEqual(recovered.run.state, .running)
                XCTAssertEqual(recovered.checkpoint.payload, next.checkpoint.payload)
                XCTAssertEqual(recovered.run.revision, 2)
            }
            XCTAssertEqual(recovered.run.revision, recovered.checkpoint.revision)
            return "state inspected"
        }
    }

    func testRejectedBundleDoesNotPartiallyUpdateRunOrCheckpoint() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let old = try await Self.seed(store)
        for (state, identity, error): (BoneWorkflowRunState, String?, BoneWorkflowFailure) in [(.running, "wrong", .corruptedCheckpoint), (.completed, nil, .invalidStateTransition)] {
            let bad = try Self.change(old, state: state, identity: identity)
            do {
                _ = try await store.commit(run: bad.run, checkpoint: bad.checkpoint, expectedRevision: 1, leaseGeneration: 1)
                XCTFail("Invalid bundle accepted")
            } catch let actual { XCTAssertEqual(actual as? BoneWorkflowFailure, error) }
            let after = try await store.load(runID: old.run.id)
            XCTAssertEqual(after, old)
        }
    }

    func testConcurrentCASHasExactlyOneWinner() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let old = try await Self.seed(store)
        let next = try Self.change(old)
        let successes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 { group.addTask {
                do { _ = try await store.commit(run: next.run, checkpoint: next.checkpoint, expectedRevision: 1, leaseGeneration: 1); return true }
                catch { XCTAssertEqual(error as? BoneWorkflowFailure, .revisionConflict); return false }
            } }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let saved = try await store.load(runID: old.run.id)
        XCTAssertEqual(saved.run.revision, 2)
        XCTAssertEqual(saved.checkpoint.revision, 2)
    }

    func testNewGenerationFencesLateWorkerEvenWithFreshRevision() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let old = try await Self.seed(store)
        let takeover = try await store.acquireLease(runID: old.run.id, expectedRevision: 1)
        XCTAssertEqual(takeover.run.leaseGeneration, 2)
        XCTAssertEqual(takeover.run.revision, 2)
        XCTAssertEqual(takeover.checkpoint.revision, 2)
        XCTAssertEqual(takeover.checkpoint.payload, old.checkpoint.payload)
        for snapshot in [try Self.change(old), try Self.change(takeover, generation: 1)] {
            do {
                _ = try await store.commit(run: snapshot.run, checkpoint: snapshot.checkpoint, expectedRevision: snapshot.run.revision, leaseGeneration: 1)
                XCTFail("Old worker committed")
            } catch { XCTAssertEqual(error as? BoneWorkflowFailure, snapshot.run.revision == 1 ? .revisionConflict : .leaseConflict) }
        }
        let unchanged = try await store.load(runID: old.run.id)
        XCTAssertEqual(unchanged, takeover)
        let next = try Self.change(takeover)
        let committed = try await store.commit(run: next.run, checkpoint: next.checkpoint, expectedRevision: 2, leaseGeneration: 2)
        XCTAssertEqual(committed.run.revision, 3)
    }
}
