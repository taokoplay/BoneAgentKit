import Foundation

/// Session、Agent Step checkpoint 和私有执行快照之间的绑定校验错误。
public enum BoneAgentExecutionSessionBindingError: Error, Codable, Equatable, Sendable {
    case missingSessionSnapshotReference
    case missingCheckpointSnapshotReference
    case sessionSnapshotMismatch
    case runMismatch
    case stepMismatch
    case attemptMismatch
    case revisionMismatch
    case leaseMismatch
}

/// 验证长期 Agent 执行的控制面引用是否指向同一个恢复边界。
public enum BoneAgentExecutionSessionBindingValidator {
    /// 校验 Session、Step checkpoint 和可选私有快照的身份、revision 与 lease。
    /// - Parameters:
    ///   - session: 当前持久化的 Agent Execution Session。
    ///   - checkpoint: 当前持久化的 Agent Step checkpoint。
    ///   - snapshot: 可选的 Host-owned 私有执行快照。
    /// - Throws: 任一对象缺少引用或三方绑定不一致时抛出绑定校验错误。
    public static func validate(
        session: BoneAgentExecutionSession,
        checkpoint: BoneWorkflowAgentStepCheckpoint,
        snapshot: BoneWorkflowAgentExecutionSnapshot? = nil
    ) throws {
        guard let sessionReference = session.snapshotReference else {
            throw BoneAgentExecutionSessionBindingError.missingSessionSnapshotReference
        }
        guard let checkpointReference = checkpoint.executionSnapshotReference else {
            throw BoneAgentExecutionSessionBindingError.missingCheckpointSnapshotReference
        }
        guard sessionReference == checkpointReference else {
            throw BoneAgentExecutionSessionBindingError.sessionSnapshotMismatch
        }
        guard session.runID == checkpoint.runID,
              sessionReference.runID == session.runID else {
            throw BoneAgentExecutionSessionBindingError.runMismatch
        }
        guard sessionReference.stepID == checkpoint.stepID else {
            throw BoneAgentExecutionSessionBindingError.stepMismatch
        }
        guard sessionReference.attemptID == checkpoint.attemptID else {
            throw BoneAgentExecutionSessionBindingError.attemptMismatch
        }
        guard sessionReference.checkpointRevision == checkpoint.persistenceRevision else {
            throw BoneAgentExecutionSessionBindingError.revisionMismatch
        }
        guard sessionReference.leaseGeneration == checkpoint.leaseGeneration else {
            throw BoneAgentExecutionSessionBindingError.leaseMismatch
        }
        if let snapshot, snapshot.reference != sessionReference {
            throw BoneAgentExecutionSessionBindingError.sessionSnapshotMismatch
        }
    }
}
