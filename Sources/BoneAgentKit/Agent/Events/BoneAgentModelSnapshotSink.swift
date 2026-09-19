import Foundation

/// 接收 Run 模型快照的 observer；与 `BoneAgentEventSink` 平行，不是持久事实源。
///
/// Kit 在 Run 终态确定之后、返回值或错误抛出之前投递且只投递一次，因此调用方在拿到
/// 结果或捕获错误时，快照一定已经交付完毕。投递是 `await` 的：闭包内的耗时会计入 Run
/// 自身的执行时间并占用 Agent 的串行执行上下文。需要落盘或跨会话聚合的 Host 应在闭包
/// 内只做内存暂存或转发，把持久化交给自己的任务，否则落盘时间会被算进 Run。
///
/// Kit 不为投递设超时，也不在投递期间释放 Run 占用：sink 挂死会让该 Agent 之后的每次
/// `run` 都直接得到 `runAlreadyInProgress`，因此 sink 必须尽快返回。
public struct BoneAgentModelSnapshotSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentRunModelSnapshot) async -> Void

    public init(
        _ receive: @escaping @Sendable (BoneAgentRunModelSnapshot) async -> Void = { _ in }
    ) {
        receiveClosure = receive
    }

    public func receive(_ snapshot: BoneAgentRunModelSnapshot) async {
        await receiveClosure(snapshot)
    }
}
