import Foundation

/// 可选恢复发现能力，与 Persistence 的精确 ID 读写契约分离。
/// 返回当前实例授权 scope 内完整、一致的扫描快照；不得静默截断或跨 scope 扫描。
/// 单条记录解码/信封不一致可隔离；连接、权限、事务失败及取消必须抛出，不能计为坏行。
/// 扫描是只读的，不删除/改写坏记录、不获取 lease；执行前仍须 load/CAS 与 Host 授权。
public protocol BoneWorkflowRecoveryScan: Sendable {
    func recoverableRunScan() async throws -> BoneWorkflowRecoveryScanResult
}

/// 包含完整 checkpoint，可能带有业务数据；不是可直接打印/导出的安全诊断报告。
/// trusted 仅表示信封有效，不证明业务 schema、版本兼容性、执行授权或 Effect 安全。
public struct BoneWorkflowRecoveryScanResult: Equatable, Sendable {
    /// 顺序不作保证；Run ID 唯一。包含待推进状态与 recoveryRequired，后者必须人工/Host 调和。
    public let trustedRuns: [BoneWorkflowRunSnapshot]
    /// 同一 scope 快照中不可用记录数，包括不能解码状态的记录；不是历史累计数。
    /// 不含合法 completed/failed/cancelled，不泄露坏记录正文或身份。
    public let quarantinedRunCount: Int

    public init(trustedRuns: [BoneWorkflowRunSnapshot], quarantinedRunCount: Int) throws {
        guard quarantinedRunCount >= 0,
              Set(trustedRuns.map(\.run.id)).count == trustedRuns.count,
              trustedRuns.allSatisfy({ snapshot in
                  Self.includes(snapshot.run.state)
                      && snapshot.run.revision > 0
                      && snapshot.run.revision == snapshot.checkpoint.revision
                      && snapshot.checkpoint.descriptor.workflowIdentity == snapshot.run.plan.identity
                      && snapshot.checkpoint.descriptor.workflowRevision == snapshot.run.plan.revision
              }) else { throw BoneWorkflowFailure.corruptedCheckpoint }
        self.trustedRuns = trustedRuns
        self.quarantinedRunCount = quarantinedRunCount
    }

    /// 表示应出现在恢复发现结果中，不表示可以自动执行或接管。
    public static func includes(_ state: BoneWorkflowRunState) -> Bool {
        switch state {
        case .pending, .running, .pausing, .paused, .waitingForAuthorization, .cancelling, .recoveryRequired: return true
        case .completed, .failed, .cancelled: return false
        }
    }
}
