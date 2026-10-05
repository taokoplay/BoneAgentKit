import Foundation

/// Host 专用私有上下文存储的引用，不是摘要正文。不得放入 URL/路径/凭据。
/// 该协议不参与标准 WorkflowPersistence，也不会被 Agent 隐式调用。
public struct BoneContextHistoryReference: Codable, Equatable, Sendable {
    public let opaqueID: String
    public let revision: UInt64
    public let leaseGeneration: UInt64

    public init(opaqueID: String, revision: UInt64, leaseGeneration: UInt64) throws {
        guard (1...128).contains(opaqueID.utf8.count), revision > 0,
              opaqueID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.").contains($0) }) else {
            throw BoneContextHistoryPersistenceError.invalidReference
        }
        self.opaqueID = opaqueID; self.revision = revision; self.leaseGeneration = leaseGeneration
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(opaqueID: c.decode(String.self, forKey: .opaqueID), revision: c.decode(UInt64.self, forKey: .revision),
                      leaseGeneration: c.decode(UInt64.self, forKey: .leaseGeneration))
    }
    private enum CodingKeys: CodingKey { case opaqueID, revision, leaseGeneration }
}

public enum BoneContextHistoryPersistenceError: Error, Equatable, Sendable {
    case invalidReference, revisionConflict, leaseMismatch, outcomeUnknown
}

/// Host 显式选用的安全引用 CAS 契约。正文加密、内容完整性、保留/清理策略与授权由 Host 负责。
/// commit 只关联已持久化的私有内容引用；不等于保存正文，也不恢复 Agent/工具执行状态。
/// 结果未知先 load 核对，不得换 revision 盲目重试；不提供无验证默认实现。
public protocol BoneContextHistoryPersistence: Sendable {
    func load(runID: BoneRunID) async throws -> BoneContextHistoryReference?
    /// 首次 expected=nil，否则必须与当前完整引用相等；generation 由 Host Run 所有权确定。
    /// 只能提交 revision=1（首次）或 expected.revision+1，禁止溢出、跨代回写。
    func commit(runID: BoneRunID, reference: BoneContextHistoryReference,
                expected: BoneContextHistoryReference?, leaseGeneration: UInt64) async throws
}
