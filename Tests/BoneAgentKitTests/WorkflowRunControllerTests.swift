import Foundation
import XCTest
import BoneAgentKit

final class WorkflowRunControllerTests: XCTestCase {
    func testPendingStartAcquiresLeaseAndPreservesCheckpoint() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        XCTAssertEqual(created.run.state, .pending)
        XCTAssertEqual(created.run.leaseGeneration, 0)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        XCTAssertEqual(running.run.state, .running)
        XCTAssertEqual(running.run.leaseGeneration, 1)
        XCTAssertEqual(running.run.revision, 3)
        XCTAssertEqual(running.checkpoint.payload, created.checkpoint.payload)
    }

    func testPauseAndResumeEachFencePreviousWorker() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        let paused = try await controller.pauseExecution(runID: created.run.id, expectedRevision: running.run.revision)
        XCTAssertEqual(paused.run.state, .paused)
        XCTAssertEqual(paused.run.leaseGeneration, 2)
        let resumed = try await controller.resumePausedExecution(runID: created.run.id, expectedRevision: paused.run.revision)
        XCTAssertEqual(resumed.run.state, .running)
        XCTAssertEqual(resumed.run.leaseGeneration, 3)
        for generation in [running.run.leaseGeneration, paused.run.leaseGeneration] {
            do {
                _ = try await controller.reconcileTerminal(runID: created.run.id, state: .completed,
                    expectedRevision: resumed.run.revision, leaseGeneration: generation)
                XCTFail("Old worker must not finish a resumed run")
            } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .leaseConflict) }
        }
    }

    func testCancellationIsDurableBeforeWorkerStopAndNotAutomaticallyTerminal() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let requested = try await controller.requestCancellation(runID: created.run.id, expectedRevision: 1)
        XCTAssertEqual(requested.run.state, .cancelling)
        try await controller.stopRequestedExecution(runID: created.run.id, expectedRevision: requested.run.revision,
            leaseGeneration: requested.run.leaseGeneration) { snapshot in
                let durable = try await store.load(runID: snapshot.run.id)
                XCTAssertEqual(durable, snapshot)
                XCTAssertEqual(durable.run.state, .cancelling)
            }
        let after = try await store.load(runID: created.run.id)
        XCTAssertEqual(after, requested)
        let cancelled = try await controller.reconcileTerminal(runID: created.run.id, state: .cancelled,
            expectedRevision: after.run.revision, leaseGeneration: after.run.leaseGeneration)
        XCTAssertEqual(cancelled.run.state, .cancelled)
    }

    func testRecoveryDoesNotResetBudgetOrChangeState() async throws {
        let controller = BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence())
        let created = try await create(controller)
        let recovered = try await controller.recover(runID: created.run.id, expectedRevision: 1)
        XCTAssertEqual(recovered.run.state, created.run.state)
        XCTAssertEqual(recovered.run.plan, created.run.plan)
        XCTAssertEqual(recovered.checkpoint.payload, created.checkpoint.payload)
        XCTAssertEqual(recovered.run.leaseGeneration, 1)
    }

    func testPreparedCheckpointOnlyBindsWhilePending() async throws {
        let controller = BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence())
        let created = try await create(controller)
        let prepared = try BoneWorkflowCheckpoint(descriptor: created.checkpoint.descriptor,
            payload: Data("{\"prepared\":true}".utf8), dataClassification: .safeState, revision: 1)
        let bound = try await controller.bindPreparedExecution(runID: created.run.id, expectedRevision: 1, checkpoint: prepared)
        XCTAssertEqual(bound.checkpoint.payload, prepared.payload)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: bound.run.revision)
        do {
            _ = try await controller.bindPreparedExecution(runID: created.run.id, expectedRevision: running.run.revision, checkpoint: prepared)
            XCTFail("Must not rebind executing Run")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .invalidStateTransition) }
    }

    func testTerminalCannotRecoverOrRestart() async throws {
        let controller = BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence())
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        let completed = try await controller.reconcileTerminal(runID: created.run.id, state: .completed,
            expectedRevision: running.run.revision, leaseGeneration: running.run.leaseGeneration)
        do {
            _ = try await controller.recover(runID: created.run.id, expectedRevision: completed.run.revision)
            XCTFail("Terminal cannot acquire another lease through controller")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .invalidStateTransition) }
        do {
            _ = try await controller.beginExecution(runID: created.run.id, expectedRevision: completed.run.revision)
            XCTFail("Terminal cannot restart")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .invalidStateTransition) }
    }

    func testStartingNonzeroGenerationStillAcquiresNewLease() async throws {
        let base = BoneInMemoryWorkflowPersistence()
        let temporary = try await create(BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence()))
        let checkpoint = try BoneWorkflowCheckpoint(descriptor: temporary.checkpoint.descriptor,
            payload: temporary.checkpoint.payload, dataClassification: .safeState)
        _ = try await base.create(run: .init(id: temporary.run.id, plan: temporary.run.plan,
            state: .pending, revision: 0, leaseGeneration: 7), checkpoint: checkpoint)
        let running = try await BoneWorkflowRunController(persistence: base).beginExecution(runID: temporary.run.id, expectedRevision: 1)
        XCTAssertEqual(running.run.leaseGeneration, 8)
    }

    func testUnknownAcquireResultDoesNotProceedOrRetry() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        await store.setFault(.acquireAfterWrite)
        do {
            _ = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
            XCTFail("Uncertain acquire must stop")
        } catch { XCTAssertTrue(error is ControlFault) }
        let stored = try await store.load(runID: created.run.id)
        let acquisitions = await store.acquisitions
        let commits = await store.commits
        XCTAssertEqual(stored.run.state, .pending)
        XCTAssertEqual(stored.run.leaseGeneration, 1)
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(commits, 0)
    }

    func testInvalidLeaseReceiptDoesNotPermitRunningCommit() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        await store.setFault(.invalidLeaseReceipt)
        do {
            _ = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
            XCTFail("Invalid receipt must stop")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .corruptedCheckpoint) }
        let commits = await store.commits
        XCTAssertEqual(commits, 0)
    }

    func testUnknownPausingCommitLeavesIntentAndDoesNotAcquire() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        await store.setFault(.commitAfterWrite)
        do {
            _ = try await controller.pauseExecution(runID: created.run.id, expectedRevision: running.run.revision)
            XCTFail("Uncertain pausing write must stop")
        } catch { XCTAssertTrue(error is ControlFault) }
        let stored = try await store.load(runID: created.run.id)
        let acquisitions = await store.acquisitions
        XCTAssertEqual(stored.run.state, .pausing)
        XCTAssertEqual(stored.run.leaseGeneration, running.run.leaseGeneration)
        XCTAssertEqual(acquisitions, 1)
        // Explicit Host reconciliation can continue from the durable pausing intent.
        await store.setFault(.none)
        let paused = try await controller.pauseExecution(runID: created.run.id, expectedRevision: stored.run.revision)
        XCTAssertEqual(paused.run.state, .paused)
        XCTAssertEqual(paused.run.leaseGeneration, 2)
    }

    func testPauseConflictAfterAcquisitionDoesNotRollbackOrRetry() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        await store.setFault(.rejectPaused)
        do {
            _ = try await controller.pauseExecution(runID: created.run.id, expectedRevision: running.run.revision)
            XCTFail("CAS failure must stop")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .revisionConflict) }
        let stored = try await store.load(runID: created.run.id)
        XCTAssertEqual(stored.run.state, .pausing)
        XCTAssertEqual(stored.run.leaseGeneration, 2)
        let acquisitions = await store.acquisitions
        XCTAssertEqual(acquisitions, 2)
    }

    func testConcurrentControllersHaveOnlyOneStartWinner() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let created = try await create(BoneWorkflowRunController(persistence: store))
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await BoneWorkflowRunController(persistence: store).beginExecution(runID: created.run.id, expectedRevision: 1)
                        return true
                    } catch {
                        XCTAssertEqual(error as? BoneWorkflowFailure, .revisionConflict)
                        return false
                    }
                }
            }
            var count = 0
            for await won in group { if won { count += 1 } }
            return count
        }
        XCTAssertEqual(wins, 1)
        let stored = try await store.load(runID: created.run.id)
        XCTAssertEqual(stored.run.state, .running)
        XCTAssertEqual(stored.run.leaseGeneration, 1)
    }

    func testWorkerStopFailureKeepsCancellationIntent() async throws {
        let store = BoneInMemoryWorkflowPersistence()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let intent = try await controller.requestCancellation(runID: created.run.id, expectedRevision: 1)
        do {
            try await controller.stopRequestedExecution(runID: created.run.id, expectedRevision: intent.run.revision,
                leaseGeneration: intent.run.leaseGeneration) { _ in throw ControlFault() }
            XCTFail("Worker failure must escape")
        } catch { XCTAssertTrue(error is ControlFault) }
        let stored = try await store.load(runID: created.run.id)
        XCTAssertEqual(stored, intent)
    }

    func testUnknownCancellationCommitDoesNotBecomeCancelled() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        await store.setFault(.commitAfterWrite)
        do {
            _ = try await controller.requestCancellation(runID: created.run.id, expectedRevision: 1)
            XCTFail("Uncertain cancellation commit must escape")
        } catch { XCTAssertTrue(error is ControlFault) }
        let stored = try await store.load(runID: created.run.id)
        XCTAssertEqual(stored.run.state, .cancelling)
        let commits = await store.commits
        XCTAssertEqual(commits, 1)
    }

    func testTerminalReconciliationIsIdempotentButCannotChangeTerminal() async throws {
        let controller = BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence())
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        let completed = try await controller.reconcileTerminal(runID: created.run.id, state: .completed,
            expectedRevision: running.run.revision, leaseGeneration: running.run.leaseGeneration)
        let repeated = try await controller.reconcileTerminal(runID: created.run.id, state: .completed,
            expectedRevision: completed.run.revision, leaseGeneration: completed.run.leaseGeneration)
        XCTAssertEqual(repeated, completed)
        do {
            _ = try await controller.reconcileTerminal(runID: created.run.id, state: .failed,
                expectedRevision: completed.run.revision, leaseGeneration: completed.run.leaseGeneration)
            XCTFail("Terminal cannot change")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .invalidStateTransition) }
    }

    func testCancellationAfterLeaseWriteStopsBeforeRunning() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        await store.setFault(.cancelAfterAcquire)
        let task = Task { try await controller.beginExecution(runID: created.run.id, expectedRevision: 1) }
        do { _ = try await task.value; XCTFail("Cancellation must escape") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let stored = try await store.load(runID: created.run.id)
        let commits = await store.commits
        XCTAssertEqual(stored.run.state, .pending)
        XCTAssertEqual(stored.run.leaseGeneration, 1)
        XCTAssertEqual(commits, 0)
    }

    func testInvalidCommitReceiptStopsPauseBeforeLeaseAcquisition() async throws {
        let store = ControlFaultStore()
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await create(controller)
        let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
        await store.setFault(.invalidCommitReceipt)
        do {
            _ = try await controller.pauseExecution(runID: created.run.id, expectedRevision: running.run.revision)
            XCTFail("Invalid commit receipt must stop")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .corruptedCheckpoint) }
        let acquisitions = await store.acquisitions
        let stored = try await store.load(runID: created.run.id)
        XCTAssertEqual(acquisitions, 1)
        XCTAssertEqual(stored.run.state, .pausing)
    }

    func testStaleGenerationCannotInvokeWorkerStop() async throws {
        let controller = BoneWorkflowRunController(persistence: BoneInMemoryWorkflowPersistence())
        let created = try await create(controller)
        let intent = try await controller.requestCancellation(runID: created.run.id, expectedRevision: 1)
        let recovered = try await controller.recover(runID: created.run.id, expectedRevision: intent.run.revision)
        do {
            try await controller.stopRequestedExecution(runID: created.run.id, expectedRevision: recovered.run.revision,
                leaseGeneration: intent.run.leaseGeneration) { _ in XCTFail("Stale callback invoked") }
            XCTFail("Stale generation must fail")
        } catch { XCTAssertEqual(error as? BoneWorkflowFailure, .leaseConflict) }
    }

    private func create(_ controller: BoneWorkflowRunController) async throws -> BoneWorkflowRunSnapshot {
        let plan = try BoneWorkflowPlan(identity: "control-test", revision: 1,
            steps: [.init(id: .init("step"), kind: "work", revision: 1)])
        let checkpoint = try BoneWorkflowCheckpoint(
            descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1),
            payload: Data("{\"requestLimit\":10,\"used\":3,\"deadline\":1000}".utf8), dataClassification: .safeState)
        return try await controller.createRun(runID: .init("run"), plan: plan, checkpoint: checkpoint)
    }
}

private struct ControlFault: Error {}

private actor ControlFaultStore: BoneWorkflowPersistence {
    enum Fault { case none, acquireAfterWrite, invalidLeaseReceipt, commitAfterWrite, rejectPaused, cancelAfterAcquire, invalidCommitReceipt }
    private let base = BoneInMemoryWorkflowPersistence()
    private var fault = Fault.none
    var acquisitions = 0
    var commits = 0
    func setFault(_ fault: Fault) { self.fault = fault }

    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot {
        try await base.create(run: run, checkpoint: checkpoint)
    }
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot { try await base.load(runID: runID) }
    func commit(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint, expectedRevision: UInt64, leaseGeneration: UInt64) async throws -> BoneWorkflowRunSnapshot {
        commits += 1
        if fault == .rejectPaused && run.state == .paused { throw BoneWorkflowFailure.revisionConflict }
        let saved = try await base.commit(run: run, checkpoint: checkpoint, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
        if fault == .commitAfterWrite { throw ControlFault() }
        if fault == .invalidCommitReceipt { return .init(run: run, checkpoint: checkpoint) }
        return saved
    }
    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        acquisitions += 1
        let saved = try await base.acquireLease(runID: runID, expectedRevision: expectedRevision)
        if fault == .acquireAfterWrite { throw ControlFault() }
        if fault == .cancelAfterAcquire { withUnsafeCurrentTask { $0?.cancel() } }
        if fault == .invalidLeaseReceipt {
            return .init(run: .init(id: saved.run.id, plan: saved.run.plan, state: .running,
                revision: saved.run.revision, leaseGeneration: saved.run.leaseGeneration), checkpoint: saved.checkpoint)
        }
        return saved
    }
}
