import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 只在当前请求中使用的事件源，避免把有界流再包装进无界 AsyncThrowingStream。
enum BoneInferenceEventSource<Element: Sendable>: AsyncSequence, Sendable {
    case legacy(AsyncThrowingStream<Element, Error>)
    case bounded(BoneBoundedEventStream<Element>)

    struct AsyncIterator: AsyncIteratorProtocol {
        var legacy: AsyncThrowingStream<Element, Error>.Iterator?
        var bounded: BoneBoundedEventStream<Element>.AsyncIterator?

        mutating func next() async throws -> Element? {
            if var iterator = legacy {
                defer { legacy = iterator }
                return try await iterator.next()
            }
            if var iterator = bounded {
                defer { bounded = iterator }
                return try await iterator.next()
            }
            return nil
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        switch self {
        case .legacy(let stream): return .init(legacy: stream.makeAsyncIterator())
        case .bounded(let stream): return .init(bounded: stream.makeAsyncIterator())
        }
    }
}

/// 三家 Provider 共用生产与退出逻辑；协议解析、结果复验仍由各自实现负责。
enum BoneInferenceEventStreams {
    typealias Emit<Element: Sendable> = @Sendable (Element) async throws -> Void

    static func legacy<Element: Sendable>(
        operation: @escaping @Sendable (@escaping Emit<Element>) async throws -> Void
    ) -> AsyncThrowingStream<Element, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = BoneEventProducerCancellation()
            let task = Task {
                do {
                    try await operation { event in
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            cancellation.install(task)
            continuation.onTermination = { @Sendable _ in cancellation.cancel() }
        }
    }

    static func bounded<Element: Sendable>(
        buffering: BoneEventBufferLimits,
        options: BoneInferenceEventStreamOptions? = nil,
        payloadSize: @escaping @Sendable (Element) -> Int,
        operation: @escaping @Sendable (@escaping Emit<Element>) async throws -> Void
    ) -> BoneBoundedEventStream<Element> {
        let (stream, producer) = BoneBoundedEventStream<Element>.makeStream(
            limits: buffering, payloadSize: payloadSize
        )
        let cancellation = BoneEventProducerCancellation()
        producer.onTermination { termination in
            // send 失败会自行抛错收口；自取消会让 deadline 子任务的取消错误抢先返回。
            // 只有消费者取消需要主动中断仍在生产的任务。
            if case .cancelled = termination { cancellation.cancel() }
        }
        let task = Task {
            do {
                let deadline = try options.map { try deadlineUptime(options: $0) } ?? nil
                try await withDeadline(deadline) {
                    try await operation { try await producer.send($0) }
                }
                producer.finish()
            } catch { producer.finish(throwing: error) }
        }
        cancellation.install(task)
        return stream
    }

    static func validate(transport: any BoneInferenceHTTPTransport) throws {
        guard transport.providesLiveEventTiming,
              transport is any BoneInferenceFlowControlledHTTPTransport else {
            throw BoneEventStreamError.flowControlUnavailable
        }
    }

    static func source(
        transport: any BoneInferenceHTTPTransport,
        request: URLRequest,
        options: BoneInferenceEventStreamOptions,
        buffering: BoneEventBufferLimits?
    ) throws -> BoneInferenceEventSource<BoneInferenceEventStreamEvent> {
        if let buffering {
            try validate(transport: transport)
            guard let controlled = transport as? any BoneInferenceFlowControlledHTTPTransport else {
                throw BoneEventStreamError.flowControlUnavailable
            }
            return .bounded(controlled.eventStream(request, options: options, buffering: buffering))
        }
        return .legacy(transport.eventStream(request, options: options))
    }

    static func deadlineUptime(options: BoneInferenceEventStreamOptions) throws -> TimeInterval? {
        guard options.totalTimeout.map({ $0.isFinite && $0 > 0 }) != false,
              options.deadlineUptime.map({ $0.isFinite }) != false else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        let relative = options.totalTimeout.map { ProcessInfo.processInfo.systemUptime + $0 }
        return [relative, options.deadlineUptime].compactMap { $0 }.min()
    }

    /// 一个操作共用一个截止竞争，不为每个 token 建立 Task。内部 send/next 必须配合取消。
    static func withDeadline<Value: Sendable>(
        _ deadline: TimeInterval?,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard let deadline else { return try await operation() }
        guard deadline > ProcessInfo.processInfo.systemUptime else {
            throw BoneInferenceStreamDeadlineExceeded()
        }
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                while true {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    if remaining <= 0 { throw BoneInferenceStreamDeadlineExceeded() }
                    try await Task.sleep(nanoseconds: UInt64(min(remaining, 3_600) * 1_000_000_000))
                }
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw CancellationError() }
            return value
        }
    }
}

/// 解决取消早于 Task 安装的竞争；安装、取消与生命周期清理不持锁调用用户代码。
final class BoneEventProducerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func install(_ task: Task<Void, Never>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

/// 字节计量仅覆盖事件的逻辑载荷与固定信封开销，不等同于进程 RSS。
/// 正式 Codable 响应按其内存中的 JSON 表示计量；不会写日志或保存编码结果。
enum BoneEventPayloadSize {
    static func sum(_ values: Int...) -> Int {
        var result = 0
        for value in values {
            guard value >= 0 else { return -1 }
            let (next, overflow) = result.addingReportingOverflow(value)
            if overflow { return -1 }
            result = next
        }
        return result
    }

    static func encoded<Value: Encodable>(_ value: Value) -> Int {
        (try? JSONEncoder().encode(value).count) ?? -1
    }

    static func raw(_ event: BoneInferenceEventStreamEvent) -> Int {
        sum(32, event.data.utf8.count, event.event?.utf8.count ?? 0, event.id?.utf8.count ?? 0)
    }

    static func normalized(_ event: BoneInferenceStreamEvent) -> Int {
        switch event {
        case .reasoningStarted, .reasoningCompleted: return 32
        case .reasoningDelta(let text), .textDelta(let text): return sum(32, text.utf8.count)
        case .toolCallStarted(let id, let toolID): return sum(32, id.utf8.count, toolID.utf8.count)
        case .toolArgumentsDelta(let id, let data): return sum(32, id.utf8.count, data.count)
        case .toolCallCompleted(let id): return sum(32, id.utf8.count)
        case .usage(let usage): return sum(32, encoded(usage))
        case .completed(let result):
            return sum(32, encoded(result.response), result.reasoning?.text.utf8.count ?? 0)
        }
    }

    static func agent(_ event: BoneAgentStreamEvent) -> Int {
        switch event {
        case .runStarted, .reasoningStarted, .reasoningCompleted: return 64
        case .reasoningDelta(_, let text), .textDelta(_, let text): return sum(64, text.utf8.count)
        case .modelToolCallStarted(_, let callID, let toolID),
             .modelToolCallFinished(_, let callID, let toolID),
             .toolExecutionStarted(_, let callID, let toolID),
             .toolResultReady(_, let callID, let toolID, _):
            return sum(64, callID.utf8.count, toolID.utf8.count)
        case .usage(_, let usage): return sum(64, encoded(usage))
        case .completed(let result): return sum(64, encoded(result))
        }
    }
}

/// 自定义流控 Transport 仍需遵守请求级总响应预算，不能靠逐个消费绕开总量限制。
struct BoneInferenceFlowPayloadBudget {
    let maximumBytes: Int
    private var receivedBytes = 0

    init(maximumBytes: Int) { self.maximumBytes = max(0, maximumBytes) }

    mutating func record(_ event: BoneInferenceEventStreamEvent) throws {
        let bytes = BoneEventPayloadSize.sum(event.data.utf8.count,
            event.event?.utf8.count ?? 0, event.id?.utf8.count ?? 0)
        guard bytes >= 0, bytes <= maximumBytes - receivedBytes else {
            throw BoneInferenceTransportError.responseTooLarge
        }
        receivedBytes += bytes
    }
}
