import Foundation

extension BoneWorkflowWorkLedger {
    /// 可信 Host 对旧在途页的明确结论，不是 Worker 回调，也不是可自行认证的授权凭证。
    /// evidenceID 必须指向 Host 保留的对账依据；SDK 只检查其形状，不读取或认证该证据。
    public struct Reconciliation: Codable, Equatable, Sendable {
        public enum Outcome: Codable, Equatable, Sendable {
            /// Host 确认失败且不存在未知副作用。超时、无 Worker、换 lease 均不是失败证明。
            case knownFailure
            /// Host 已确认响应及其业务应用结果。SDK 不执行应用，也不验证领域 artifact 正确性。
            case committed(response: Data, cursor: Data?, artifact: Data, completed: Bool)
        }
        public let runID: BoneRunID
        public let unitID: String
        public let page: UInt64
        public let sourceGeneration: UInt64
        public let resolvingGeneration: UInt64
        public let expectedRevision: UInt64
        public let evidenceID: String
        public let outcome: Outcome

        public init(runID: BoneRunID, unitID: String, page: UInt64, sourceGeneration: UInt64,
                    resolvingGeneration: UInt64, expectedRevision: UInt64, evidenceID: String, outcome: Outcome) throws {
            guard Self.validID(unitID), Self.validID(evidenceID), sourceGeneration > 0,
                  resolvingGeneration > sourceGeneration, expectedRevision > 0 else {
                throw BoneWorkflowWorkLedgerError.invalidInput
            }
            if case .committed(let response, let cursor, let artifact, _) = outcome {
                guard response.count <= BoneWorkflowWorkLedger.maximumDataByteCount,
                      (cursor?.count ?? 0) <= BoneWorkflowWorkLedger.maximumDataByteCount,
                      artifact.count <= BoneWorkflowWorkLedger.maximumDataByteCount else {
                    throw BoneWorkflowWorkLedgerError.invalidInput
                }
            }
            self.runID = runID; self.unitID = unitID; self.page = page
            self.sourceGeneration = sourceGeneration; self.resolvingGeneration = resolvingGeneration
            self.expectedRevision = expectedRevision; self.evidenceID = evidenceID; self.outcome = outcome
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(runID: c.decode(BoneRunID.self, forKey: .runID), unitID: c.decode(String.self, forKey: .unitID),
                page: c.decode(UInt64.self, forKey: .page), sourceGeneration: c.decode(UInt64.self, forKey: .sourceGeneration),
                resolvingGeneration: c.decode(UInt64.self, forKey: .resolvingGeneration),
                expectedRevision: c.decode(UInt64.self, forKey: .expectedRevision), evidenceID: c.decode(String.self, forKey: .evidenceID),
                outcome: c.decode(Outcome.self, forKey: .outcome))
        }
        private static func validID(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 128
        }
    }
}

/// 可选旧页对账能力；原 WorkLedgerStore 的普通 Worker 路径不放宽 generation 围栏。
/// Host 必须认证当前接管者、阻止旧执行再产生副作用，并在事务内复核证据与精确目标。
/// 单次 reconcile 原子校验 revision/generation 并写回页、进度与审计依据；不得部分提交。
/// 不能将任意 evidenceID 或解码后的 Reconciliation 当作授权。未知提交先 load，不盲目重试。
public protocol BoneWorkflowWorkReconciliationStore: BoneWorkflowWorkLedgerStore {
    func reconcile(_ reconciliation: BoneWorkflowWorkLedger.Reconciliation) async throws -> BoneWorkflowWorkLedger
}
