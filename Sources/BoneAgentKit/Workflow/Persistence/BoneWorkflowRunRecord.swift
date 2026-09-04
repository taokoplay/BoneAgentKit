import Foundation

public struct BoneWorkflowRunRecord: Codable, Equatable, Sendable {
    public let id: BoneRunID
    public let plan: BoneWorkflowPlan
    public let state: BoneWorkflowRunState
    public let revision: UInt64
    public let leaseGeneration: UInt64

    public init(id: BoneRunID, plan: BoneWorkflowPlan, state: BoneWorkflowRunState, revision: UInt64, leaseGeneration: UInt64) {
        self.id = id
        self.plan = plan
        self.state = state
        self.revision = revision
        self.leaseGeneration = leaseGeneration
    }

    func stored(revision: UInt64, leaseGeneration: UInt64? = nil) -> Self {
        .init(id: id, plan: plan, state: state, revision: revision, leaseGeneration: leaseGeneration ?? self.leaseGeneration)
    }
}

public struct BoneWorkflowRunSnapshot: Codable, Equatable, Sendable {
    public let run: BoneWorkflowRunRecord
    public let checkpoint: BoneWorkflowCheckpoint

    public init(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) {
        self.run = run
        self.checkpoint = checkpoint
    }
}
