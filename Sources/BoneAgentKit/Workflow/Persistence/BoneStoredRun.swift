import Foundation

public struct BoneStoredRun: Codable, Equatable, Sendable {
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

public struct BoneStoredRunSnapshot: Codable, Equatable, Sendable {
    public let run: BoneStoredRun
    public let checkpoint: BoneRunCheckpoint

    public init(run: BoneStoredRun, checkpoint: BoneRunCheckpoint) {
        self.run = run
        self.checkpoint = checkpoint
    }
}
