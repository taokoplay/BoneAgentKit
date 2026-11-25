import Foundation

/// 一次运行的实时事件信封；runID 与状态/Token 快照一致，不是 Workflow 的持久 Run ID。
/// sequence 只表示此流的交付顺序，不与其他观察通道的序号比较。不自动编码或持久化。
public struct BoneAgentObservedEvent: Equatable, Sendable {
    public let runID: UUID
    public let sequence: UInt64
    public let event: BoneAgentStreamEvent

    public var step: Int? {
        switch event {
        case .runStarted: return nil
        case .reasoningStarted(let step, _), .reasoningDelta(let step, _),
             .reasoningCompleted(let step), .textDelta(let step, _),
             .modelToolCallStarted(let step, _, _), .modelToolCallFinished(let step, _, _),
             .toolExecutionStarted(let step, _, _), .toolResultReady(let step, _, _, _),
             .usage(let step, _): return step
        case .completed(let result): return result.steps
        }
    }
}

/// 单消费者、可取消的有界运行观察流。提前退出迭代会请求取消生产任务。
/// 终态使用独立的单结果槽位：正文排队满时仍可结束执行；该槽位受单事件载荷上限约束。
/// 总留存预算为正文队列 + 一个受限完成结果，不包含消费者自己保留的事件。
public struct BoneAgentObservedEventStream: AsyncSequence, Sendable {
    public typealias Element = BoneAgentObservedEvent
    public let runID: UUID
    private let source: BoneBoundedEventStream<BoneAgentStreamEvent>
    private let completion: BoneAgentObservedCompletion
    private let sequence = BoneAgentObservedSequence()

    public var bufferSnapshot: BoneEventBufferSnapshot { source.bufferSnapshot }

    init(runID: UUID, source: BoneBoundedEventStream<BoneAgentStreamEvent>, completion: BoneAgentObservedCompletion) {
        self.runID = runID
        self.source = source
        self.completion = completion
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var source: BoneBoundedEventStream<BoneAgentStreamEvent>.AsyncIterator
        private let runID: UUID
        private let completion: BoneAgentObservedCompletion
        private let sequence: BoneAgentObservedSequence

        fileprivate init(source: BoneBoundedEventStream<BoneAgentStreamEvent>.AsyncIterator,
                         runID: UUID, completion: BoneAgentObservedCompletion,
                         sequence: BoneAgentObservedSequence) {
            self.source = source
            self.runID = runID
            self.completion = completion
            self.sequence = sequence
        }

        public mutating func next() async throws -> BoneAgentObservedEvent? {
            let event: BoneAgentStreamEvent
            if let value = try await source.next() {
                event = value
            } else if let result = completion.take() {
                event = .completed(result)
            } else {
                return nil
            }
            try Task.checkCancellation()
            return try sequence.wrap(event, runID: runID)
        }
    }

    public func makeAsyncIterator() -> AsyncIterator {
        .init(source: source.makeAsyncIterator(), runID: runID, completion: completion, sequence: sequence)
    }
}

/// 仅绑定当前结构化执行作用域；不同 Agent/Run 不共享身份或缓冲策略。
struct BoneAgentEventFlowScope: Sendable {
    let runID: UUID
    let buffering: BoneEventBufferLimits
}

enum BoneEventFlowContext {
    @TaskLocal static var current: BoneAgentEventFlowScope?
    static var observationID: UUID? { current?.runID }
    static var buffering: BoneEventBufferLimits? { current?.buffering }
}

final class BoneAgentObservedCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: BoneAgentBoundaryResult?

    func store(_ result: BoneAgentBoundaryResult) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> BoneAgentBoundaryResult? {
        lock.lock()
        defer { lock.unlock() }
        let result = self.result
        self.result = nil
        return result
    }
}

private final class BoneAgentObservedSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0

    func wrap(_ event: BoneAgentStreamEvent, runID: UUID) throws -> BoneAgentObservedEvent {
        lock.lock()
        defer { lock.unlock() }
        guard sequence < UInt64.max else { throw BoneAgentError.inferenceFailed }
        sequence += 1
        return .init(runID: runID, sequence: sequence, event: event)
    }
}
