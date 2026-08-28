import Foundation

/// 单次 Run 内按调用顺序投递的 observer，不是可恢复或持久状态事实源。
public struct BoneAgentEventSink: Sendable {
    private let receiveClosure: @Sendable (BoneAgentEvent) async -> Void

    public init(_ receive: @escaping @Sendable (BoneAgentEvent) async -> Void = { _ in }) {
        receiveClosure = receive
    }

    public func receive(_ event: BoneAgentEvent) async {
        await receiveClosure(event)
    }
}
