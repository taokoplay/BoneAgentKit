import Foundation

/// Host的session准入事务：apply必须原子CAS保存permit/nonce墓碑/session历史，不得分别提交。
/// Hash/nonce绑定不认证业务授权，调用方仍须提供可信Host准入与Run/Effect安全检查。
public protocol BoneWorkflowExecutionSessionStore: Sendable {
    /// 初次建立sequence0；存在时初始Request必须等值，返回原进度而非重置。
    func open(runID: BoneRunID, initial: BoneWorkflowExecutionSession.Request) async throws -> BoneWorkflowSessionLedger
    func load(runID: BoneRunID) async throws -> BoneWorkflowSessionLedger
    /// 提交未知先重读；不自动换nonce重试。nonce在Run内一次性，scope边界由Host固定。
    func apply(runID: BoneRunID, expectedRevision: UInt64, command: BoneWorkflowSessionLedger.Command) async throws -> BoneWorkflowSessionLedger
}

public actor BoneInMemoryWorkflowExecutionSessionStore: BoneWorkflowExecutionSessionStore {
    private var ledgers: [BoneRunID: BoneWorkflowSessionLedger] = [:]
    public init() {}
    public func open(runID: BoneRunID, initial: BoneWorkflowExecutionSession.Request) throws -> BoneWorkflowSessionLedger {
        try Task.checkCancellation()
        if let old = ledgers[runID] {
            guard old.initialRequest == initial else { throw BoneWorkflowExecutionSessionError.bindingMismatch }
            return old
        }
        let created = try BoneWorkflowSessionLedger(runID: runID, initial: initial)
        ledgers[runID] = created
        return created
    }
    public func load(runID: BoneRunID) throws -> BoneWorkflowSessionLedger {
        try Task.checkCancellation()
        guard let state = ledgers[runID] else { throw BoneWorkflowExecutionSessionError.missingLedger }
        return state
    }
    public func apply(runID: BoneRunID, expectedRevision: UInt64, command: BoneWorkflowSessionLedger.Command) throws -> BoneWorkflowSessionLedger {
        let old = try load(runID: runID)
        guard old.revision == expectedRevision else { throw BoneWorkflowExecutionSessionError.revisionConflict }
        let updated = try old.applying(command)
        ledgers[runID] = updated
        return updated
    }
}
