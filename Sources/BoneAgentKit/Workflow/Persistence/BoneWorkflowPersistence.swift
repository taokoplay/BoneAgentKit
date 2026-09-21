import Foundation

/// Run 与 Checkpoint 必须由同一实现原子提交；不得拆成两个无法协调的 Store。
/// Checkpoint payload 是通过 BoneWorkflowCheckpoint 校验的、业务 schema 不透明的 JSON。
/// 实现不得要求 Host 私有字段、解码为领域类型或重新编码 payload；create/load/commit
/// 必须按字节保留 payload 及其 descriptor、dataClassification、retention。
/// 领域 schema 校验在调用本协议之前或读取之后完成；格式、分级和原子性约束仍然适用。
public protocol BoneWorkflowPersistence: Sendable {
    /// 仅创建不存在的 Run；输入 Run/Checkpoint revision 均为 0，成功后均为 1。
    /// 接受任意 UInt64 leaseGeneration（含 0），必须原样保存，不隐式获取 lease。
    /// 初始 generation 不代表执行授权或 owner；调用方仍须遵守 Host 接管策略。
    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot
    func commit(
        run: BoneWorkflowRunRecord,
        checkpoint: BoneWorkflowCheckpoint,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowRunSnapshot
    /// 以 expectedRevision 做 CAS，同时递增 Run/Checkpoint revision 与 leaseGeneration，
    /// 保留其余字段。旧 revision 重放抛 revisionConflict，不修改 snapshot；此调用不是幂等的。
    /// 任一计数溢出同样抛 revisionConflict 且不修改数据，不得回绕或归零。
    /// 结果未知时先 load 并由 Host 核对所有权，不能自动用新 revision 再次接管。
    /// 此接口不包含 owner、到期时间或续租；谁可接管由 Host 决定。
    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot
}
