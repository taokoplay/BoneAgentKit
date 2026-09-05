import Foundation

public actor BoneInMemoryWorkflowPersistence: BoneWorkflowPersistence {
    private var snapshots: [BoneRunID: BoneWorkflowRunSnapshot] = [:]

    public init() {}

    public func create(
        run: BoneWorkflowRunRecord,
        checkpoint: BoneWorkflowCheckpoint
    ) throws -> BoneWorkflowRunSnapshot {
        guard snapshots[run.id] == nil,
              run.revision == 0,
              checkpoint.revision == 0,
              checkpoint.descriptor.workflowIdentity == run.plan.identity,
              checkpoint.descriptor.workflowRevision == run.plan.revision else {
            throw BoneWorkflowFailure.revisionConflict
        }
        let snapshot = try BoneWorkflowRunSnapshot(
            run: run.stored(revision: 1),
            checkpoint: checkpoint.stored(revision: 1)
        )
        snapshots[run.id] = snapshot
        return snapshot
    }

    public func load(runID: BoneRunID) throws -> BoneWorkflowRunSnapshot {
        guard let snapshot = snapshots[runID] else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        return snapshot
    }

    public func commit(
        run: BoneWorkflowRunRecord,
        checkpoint: BoneWorkflowCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneWorkflowRunSnapshot {
        guard let current = snapshots[run.id],
              current.run.revision == expectedRevision,
              current.checkpoint.revision == expectedRevision,
              run.revision == expectedRevision,
              checkpoint.revision == expectedRevision else {
            throw BoneWorkflowFailure.revisionConflict
        }
        guard current.run.leaseGeneration == leaseGeneration,
              run.leaseGeneration == leaseGeneration else {
            throw BoneWorkflowFailure.leaseConflict
        }
        guard run.plan == current.run.plan,
              checkpoint.descriptor.workflowIdentity == current.run.plan.identity,
              checkpoint.descriptor.workflowRevision == current.run.plan.revision else {
            throw BoneWorkflowFailure.corruptedCheckpoint
        }
        if run.state != current.run.state {
            _ = try current.run.state.transitioned(to: run.state)
        }
        let (next, overflow) = expectedRevision.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowFailure.revisionConflict }
        let snapshot = try BoneWorkflowRunSnapshot(
            run: run.stored(revision: next),
            checkpoint: checkpoint.stored(revision: next)
        )
        snapshots[run.id] = snapshot
        return snapshot
    }

    public func acquireLease(
        runID: BoneRunID,
        expectedRevision: UInt64
    ) throws -> BoneWorkflowRunSnapshot {
        guard let current = snapshots[runID],
              current.run.revision == expectedRevision,
              current.checkpoint.revision == expectedRevision else {
            throw BoneWorkflowFailure.revisionConflict
        }
        let (revision, revisionOverflow) = expectedRevision.addingReportingOverflow(1)
        let (generation, generationOverflow) = current.run.leaseGeneration.addingReportingOverflow(1)
        guard !revisionOverflow, !generationOverflow else {
            throw BoneWorkflowFailure.revisionConflict
        }
        let snapshot = try BoneWorkflowRunSnapshot(
            run: current.run.stored(revision: revision, leaseGeneration: generation),
            checkpoint: current.checkpoint.stored(revision: revision)
        )
        snapshots[runID] = snapshot
        return snapshot
    }
}
