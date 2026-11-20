import Foundation

/// Host-owned Agent execution snapshot 的索引。正文可以包含消息、Tool 结果和 Provider continuation，
/// 但普通 Workflow checkpoint 只保存这个经过身份与 revision 绑定的引用。
public struct BoneWorkflowAgentExecutionSnapshotReference: Codable, Equatable, Sendable {
    public let referenceID: String
    public let schemaVersion: UInt64
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let conversationRevision: UInt64
    public let contextRevision: UInt64
    public let effectLedgerRevision: UInt64
    /// 该引用所属的 Agent Step checkpoint revision。
    public let checkpointRevision: UInt64
    public let leaseGeneration: UInt64

    /// 创建绑定到一次 Agent Step checkpoint 的执行快照引用。
    /// - Parameters:
    ///   - referenceID: Host 生成的不透明快照标识。
    ///   - schemaVersion: 快照正文的 Host schema 版本。
    ///   - runID: 所属 Workflow Run 身份。
    ///   - stepID: 所属 Workflow Step 身份。
    ///   - attemptID: 所属执行 Attempt 身份。
    ///   - conversationRevision: Conversation 私有状态 revision。
    ///   - contextRevision: Context history revision。
    ///   - effectLedgerRevision: Effect ledger revision。
    ///   - checkpointRevision: 该引用将写入的 Step checkpoint revision。
    ///   - leaseGeneration: 创建引用时持有的执行代次。
    /// - Throws: 输入身份、版本或引用标识不符合合同约束时抛出 `BoneWorkflowAgentStepError.invalidState`。
    public init(
        referenceID: String,
        schemaVersion: UInt64,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        conversationRevision: UInt64,
        contextRevision: UInt64,
        effectLedgerRevision: UInt64,
        checkpointRevision: UInt64,
        leaseGeneration: UInt64
    ) throws {
        guard (1...128).contains(referenceID.utf8.count),
              referenceID.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || [45, 46, 95].contains($0)
              }),
              schemaVersion > 0, checkpointRevision > 0, leaseGeneration > 0 else {
            throw BoneWorkflowAgentStepError.invalidState
        }
        self.referenceID = referenceID
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.conversationRevision = conversationRevision
        self.contextRevision = contextRevision
        self.effectLedgerRevision = effectLedgerRevision
        self.checkpointRevision = checkpointRevision
        self.leaseGeneration = leaseGeneration
    }
}

/// Agent Workflow 的 Host-owned 执行快照。
/// 私有会话正文和 Context history 正文由 Host 保存，普通 Workflow checkpoint 只保存 reference。
public struct BoneWorkflowAgentExecutionSnapshot: Codable, Equatable, Sendable {
    /// SDK 接受的私有会话状态最大字节数，用于限制单次提交的内存和传输开销。
    public static let maximumPrivateConversationStateBytes = 8 * 1_048_576

    public let reference: BoneWorkflowAgentExecutionSnapshotReference
    /// 由 BoneAgentConversation.exportPrivateState() 产生的私有会话数据。
    public let privateConversationState: Data
    /// Context 历史正文的 Host-owned 不透明引用。
    public let contextHistoryReference: BoneContextHistoryReference?

    /// 创建待由 Host 持久化的 Agent 执行快照。
    /// - Parameters:
    ///   - reference: 与步骤 checkpoint 身份、revision 和 lease 绑定的引用。
    ///   - privateConversationState: Conversation 导出的私有状态正文。
    ///   - contextHistoryReference: 可选的 Host-owned Context history 引用。
    /// - Throws: 私有会话状态为空或超过大小上限时抛出 `invalidSnapshot`。
    public init(
        reference: BoneWorkflowAgentExecutionSnapshotReference,
        privateConversationState: Data,
        contextHistoryReference: BoneContextHistoryReference? = nil
    ) throws {
        guard !privateConversationState.isEmpty,
              privateConversationState.count <= Self.maximumPrivateConversationStateBytes else {
            throw BoneWorkflowAgentExecutionSnapshotError.invalidSnapshot
        }
        self.reference = reference
        self.privateConversationState = privateConversationState
        self.contextHistoryReference = contextHistoryReference
    }
}

/// 执行快照的 Host 存储和恢复错误。
public enum BoneWorkflowAgentExecutionSnapshotError: Error, Codable, Equatable, Sendable {
    case invalidSnapshot
    case missingSnapshot
    case revisionConflict
    case leaseMismatch
    case outcomeUnknown
}

/// Host-owned 执行快照存储合同。
/// 实现负责加密、认证、CAS、清理和跨进程持久化，SDK 不提供默认内存替代实现。
public protocol BoneWorkflowAgentExecutionSnapshotStore: Sendable {
    /// 按完整 reference 读取快照，避免只凭 opaque ID 跨 Run 取得其他会话。
    /// - Parameter reference: 需要验证执行身份的快照引用。
    /// - Returns: 与引用完全匹配的 Host-owned 执行快照。
    /// - Throws: 快照缺失、revision 冲突、lease 不匹配或 Host 无法确认结果时抛出对应错误。
    func load(
        reference: BoneWorkflowAgentExecutionSnapshotReference
    ) async throws -> BoneWorkflowAgentExecutionSnapshot

    /// 提交已经写入或即将与 Workflow checkpoint 同事务写入的快照。
    /// - Parameters:
    ///   - snapshot: 待提交的完整执行快照。
    ///   - expectedReference: nil 表示首次提交，否则必须匹配 Host 当前保存的引用。
    ///   - leaseGeneration: 发起提交的执行代次。
    /// - Returns: Host 确认提交后的快照。
    /// - Throws: CAS、lease 或 Host 持久化失败时抛出对应错误。
    func commit(
        _ snapshot: BoneWorkflowAgentExecutionSnapshot,
        expectedReference: BoneWorkflowAgentExecutionSnapshotReference?,
        leaseGeneration: UInt64
    ) async throws -> BoneWorkflowAgentExecutionSnapshot
}
