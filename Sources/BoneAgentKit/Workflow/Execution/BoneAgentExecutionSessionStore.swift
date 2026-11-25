import Foundation

/// Agent Execution Session 的 Host 持久化合同。
///
/// Store 必须使用事务或等价机制同时保证 revision 与 lease generation。提交结果未知时，调用方只能重新读取并调和，不能自动重发同一命令。
public protocol BoneAgentExecutionSessionStore: Sendable {
    /// 创建或等值读取 Session，不得用新数据覆盖已有进度。
    /// - Parameter session: 首次创建的控制面记录。
    /// - Returns: 持久化后确认的 Session。
    /// - Throws: 已存在记录身份不一致或存储失败时抛出 Store 错误。
    func open(_ session: BoneAgentExecutionSession) async throws -> BoneAgentExecutionSession

    /// 读取指定 Session 的最新持久化状态。
    /// - Parameter sessionID: Session 稳定标识。
    /// - Returns: 最新 Session 控制面记录。
    /// - Throws: Session 不存在或存储失败时抛出 Store 错误。
    func load(sessionID: String) async throws -> BoneAgentExecutionSession

    /// 使用 revision 和 lease generation 原子提交下一版 Session。
    /// - Parameters:
    ///   - session: 待提交的下一版记录。
    ///   - expectedRevision: 调用方读取到的旧 revision。
    ///   - leaseGeneration: 当前执行者持有的 lease generation。
    /// - Returns: Store 确认提交后的 Session。
    /// - Throws: revision、lease、身份或终态冲突时抛出 Store 错误。
    func commit(
        _ session: BoneAgentExecutionSession,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentExecutionSession

    /// 在同一 Host 提交边界内保存 Session 与私有执行快照。
    /// - Parameters:
    ///   - session: 待提交的下一版 Session。
    ///   - snapshot: 与 Session 引用完全匹配的私有快照。为 nil 时只提交控制面。
    ///   - expectedRevision: 调用方读取到的旧 revision。
    ///   - leaseGeneration: 当前执行者持有的 lease generation。
    /// - Returns: Host 确认提交后的 Session。
    /// - Throws: Store 不支持联合提交、revision、lease 或快照绑定不一致时抛出错误。
    func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentExecutionSession

    /// 以 CAS 方式取得下一代执行租约。
    /// - Parameters:
    ///   - sessionID: 要接管的 Session 标识。
    ///   - expectedRevision: 调用方读取到的旧 revision。
    /// - Returns: lease generation 已递增的 Session。
    /// - Throws: revision、终态或并发接管冲突时抛出 Store 错误。
    func acquireLease(
        sessionID: String,
        expectedRevision: UInt64
    ) async throws -> BoneAgentExecutionSession
}

public extension BoneAgentExecutionSessionStore {
    /// 兼容旧 Store 的默认实现。旧 Store 没有快照联合事务能力时明确拒绝带快照提交。
    /// - Parameters: 与协议方法相同。
    /// - Returns: 快照为空时调用旧控制面提交方法的结果。
    /// - Throws: 快照非空时抛出 `persistenceCapabilityUnavailable`，或转发控制面提交错误。
    func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) async throws -> BoneAgentExecutionSession {
        guard snapshot == nil else { throw BoneAgentExecutionSessionError.persistenceCapabilityUnavailable }
        return try await commit(session, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }
}

/// 仅用于 SDK 合同测试的内存 Store。
///
/// 该实现只证明单进程 actor 的原子性，不能替代 Host 的数据库事务、加密、跨进程崩溃恢复或提交结果未知测试。
public actor BoneInMemoryAgentExecutionSessionStore: BoneAgentExecutionSessionStore {
    private var sessions: [String: BoneAgentExecutionSession] = [:]

    /// 创建空的内存 Session Store。
    public init() {}

    /// 创建或等值读取 Session。
    /// - Parameter session: 首次创建的 Session。
    /// - Returns: 已保存或原先等值的 Session。
    /// - Throws: Session 无效、身份复用或任务取消时抛出错误。
    public func open(_ session: BoneAgentExecutionSession) throws -> BoneAgentExecutionSession {
        try Task.checkCancellation()
        try session.validate()
        if let existing = sessions[session.sessionID] {
            guard existing == session else { throw BoneAgentExecutionSessionError.identityReused }
            return existing
        }
        sessions[session.sessionID] = session
        return session
    }

    /// 读取内存 Store 中的 Session。
    /// - Parameter sessionID: Session 稳定标识。
    /// - Returns: 当前 Session。
    /// - Throws: Session 不存在或任务取消时抛出错误。
    public func load(sessionID: String) throws -> BoneAgentExecutionSession {
        try Task.checkCancellation()
        guard let session = sessions[sessionID] else { throw BoneAgentExecutionSessionError.missingSession }
        return session
    }

    /// 以 CAS 方式提交 Session。
    /// - Parameters:
    ///   - session: 待提交的下一版 Session。
    ///   - expectedRevision: 旧 revision。
    ///   - leaseGeneration: 当前 lease generation。
    /// - Returns: 提交后的 Session。
    /// - Throws: revision、lease、身份、状态或任务取消冲突时抛出错误。
    public func commit(
        _ session: BoneAgentExecutionSession,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        try Task.checkCancellation()
        try session.validate()
        let current = try load(sessionID: session.sessionID)
        guard current.revision == expectedRevision else { throw BoneAgentExecutionSessionError.revisionConflict }
        guard current.leaseGeneration == leaseGeneration else { throw BoneAgentExecutionSessionError.leaseConflict }
        let (nextRevision, overflow) = expectedRevision.addingReportingOverflow(1)
        guard !overflow, session.revision == nextRevision else { throw BoneAgentExecutionSessionError.revisionConflict }
        guard session.leaseGeneration == leaseGeneration else { throw BoneAgentExecutionSessionError.leaseConflict }
        guard session.runID == current.runID,
              session.conversationID == current.conversationID,
              session.modelID == current.modelID,
              session.bindingID == current.bindingID,
              session.workflowIdentity == current.workflowIdentity,
              session.workflowRevision == current.workflowRevision,
              session.configurationDigest == current.configurationDigest,
              session.toolCatalogDigest == current.toolCatalogDigest,
              session.promptProfileDigest == current.promptProfileDigest else {
            throw BoneAgentExecutionSessionError.identityMismatch
        }
        sessions[session.sessionID] = session
        return session
    }

    /// 在内存 Store 中提交无快照的控制面版本。
    /// - Parameters: 与协议方法相同。
    /// - Returns: 提交后的 Session。
    /// - Throws: 该实现不支持带快照的联合提交。
    public func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        guard snapshot == nil else { throw BoneAgentExecutionSessionError.persistenceCapabilityUnavailable }
        return try commit(session, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }

    /// 以 revision CAS 取得下一代 lease。
    /// - Parameters:
    ///   - sessionID: 要接管的 Session 标识。
    ///   - expectedRevision: 旧 revision。
    /// - Returns: lease generation 已递增并持久化的 Session。
    /// - Throws: Session 不存在、revision 冲突、终态或任务取消时抛出错误。
    public func acquireLease(
        sessionID: String,
        expectedRevision: UInt64
    ) throws -> BoneAgentExecutionSession {
        try Task.checkCancellation()
        let current = try load(sessionID: sessionID)
        guard current.revision == expectedRevision else { throw BoneAgentExecutionSessionError.revisionConflict }
        let next = try current.acquiringLease()
        sessions[sessionID] = next
        return next
    }
}
