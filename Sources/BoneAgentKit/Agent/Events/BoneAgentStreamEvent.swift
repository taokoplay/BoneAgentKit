import Foundation

/// Agent 级实时事件；只在显式 `runEvents` 流中交付，不是安全事件或持久化事实。
/// `textDelta` 是尚未完成的展示草稿，只有 `completed` 才表示已验证的正式结果。
public enum BoneAgentStreamEvent: Equatable, Sendable {
    case runStarted
    case reasoningStarted(step: Int, kind: BoneInferenceReasoning.Kind)
    case reasoningDelta(step: Int, text: String)
    case reasoningCompleted(step: Int)
    case textDelta(step: Int, text: String)
    case modelToolCallStarted(step: Int, callID: String, toolID: String)
    case modelToolCallFinished(step: Int, callID: String, toolID: String)
    case toolExecutionStarted(step: Int, callID: String, toolID: String)
    case toolResultReady(step: Int, callID: String, toolID: String, isError: Bool)
    case usage(step: Int, usage: BoneInferenceUsage)
    case completed(BoneAgentBoundaryResult)
}

/// 显式实时 Agent 流。正文、Tool 元数据和 usage 只驻留在调用方消费的内存流中。
public typealias BoneAgentEventStream = AsyncThrowingStream<BoneAgentStreamEvent, Error>


/// Bridges consumer termination to the producer task without releasing Agent ownership
/// before the underlying Provider/Tool cleanup has completed.
final class BoneAgentStreamCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
