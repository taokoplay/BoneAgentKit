import Foundation

/// Run 与 Checkpoint 必须由同一实现原子提交；不得拆成两个无法协调的 Store。
public protocol BoneAgentPersistence: Sendable {
    func create(run: BoneStoredRun, checkpoint: BoneRunCheckpoint) async throws -> BoneStoredRunSnapshot
    func load(runID: BoneRunID) async throws -> BoneStoredRunSnapshot
    func commit(
        run: BoneStoredRun,
        checkpoint: BoneRunCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneStoredRunSnapshot
    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneStoredRunSnapshot
}
