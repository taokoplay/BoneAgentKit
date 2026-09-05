import Foundation

/// Run 与 Checkpoint 必须由同一实现原子提交；不得拆成两个无法协调的 Store。
public protocol BoneWorkflowPersistence: Sendable {
    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot
    func commit(
        run: BoneWorkflowRunRecord,
        checkpoint: BoneWorkflowCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowRunSnapshot
    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot
}
