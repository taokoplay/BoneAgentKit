import Foundation

/// Limits for queued payloads. These describe queue occupancy, not process memory use.
public struct BoneEventBufferLimits: Equatable, Sendable {
    public let maximumEventCount: Int
    public let maximumQueuedPayloadBytes: Int
    public let maximumEventPayloadBytes: Int

    public init() {
        maximumEventCount = 256
        maximumQueuedPayloadBytes = 8 * 1_024 * 1_024
        maximumEventPayloadBytes = 8 * 1_024 * 1_024
    }

    public init(
        maximumEventCount: Int,
        maximumQueuedPayloadBytes: Int,
        maximumEventPayloadBytes: Int
    ) throws {
        guard maximumEventCount > 0,
              maximumQueuedPayloadBytes > 0,
              maximumEventPayloadBytes > 0,
              maximumEventPayloadBytes <= maximumQueuedPayloadBytes else {
            throw BoneEventStreamError.invalidLimits
        }
        self.maximumEventCount = maximumEventCount
        self.maximumQueuedPayloadBytes = maximumQueuedPayloadBytes
        self.maximumEventPayloadBytes = maximumEventPayloadBytes
    }
}

public enum BoneEventStreamError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidPayloadSize
    case eventTooLarge
    case bufferOverflow
    case terminated
    case multipleConsumers
    case flowControlUnavailable
}

public struct BoneEventBufferSnapshot: Equatable, Sendable {
    public let bufferedEventCount: Int
    public let bufferedPayloadBytes: Int
    public let peakBufferedEventCount: Int
    public let peakBufferedPayloadBytes: Int
}

/// A single-consumer, single-iteration stream with lossless, cancellable backpressure.
///
/// Only enqueued elements count against the budgets. An element being processed by the
/// consumer, and values retained by suspended `send` calls, are outside the queue budget.
/// Callers must also bound producer concurrency and accurately report each payload's size.
/// `offer` supports callbacks that cannot suspend: exceeding a limit fails the whole stream.
/// Releasing the iterator before exhaustion, or releasing an unconsumed stream, cancels it.
public struct BoneBoundedEventStream<Element: Sendable>: AsyncSequence, Sendable {
    public enum OfferResult: Equatable, Sendable {
        case accepted
        case terminated
        case failed(BoneEventStreamError)
    }

    public enum Termination: Equatable, Sendable {
        case finished
        case failed
        case cancelled
    }

    public struct Producer: Sendable {
        public typealias OfferResult = BoneBoundedEventStream<Element>.OfferResult
        public typealias Termination = BoneBoundedEventStream<Element>.Termination

        fileprivate let state: State

        /// Suspends in arrival order until the element fits, without blocking a thread.
        /// Cancellation before admission removes this send without cancelling the stream.
        public func send(_ element: Element) async throws {
            try await state.send(element)
        }

        /// A callback that cannot await must fail explicitly when backpressure is needed.
        @discardableResult
        public func offer(_ element: Element) -> OfferResult {
            state.offer(element)
        }

        /// Already queued elements remain readable before EOF or the original error.
        public func finish(throwing error: Error? = nil) {
            state.finish(throwing: error)
        }

        /// Installs one handler. Before termination, a new registration replaces the old one.
        /// The handler is called at most once, outside the lock, including late registration.
        public func onTermination(_ handler: @escaping @Sendable (Termination) -> Void) {
            state.onTermination(handler)
        }
    }

    public struct AsyncIterator: AsyncIteratorProtocol, Sendable {
        fileprivate let lease: IteratorLease?

        public mutating func next() async throws -> Element? {
            guard let lease else { throw BoneEventStreamError.multipleConsumers }
            return try await lease.next()
        }
    }

    private let state: State
    // Producers retain only State, so they cannot keep an unconsumed stream alive.
    private let lifetime: StreamLifetime

    private init(state: State) {
        self.state = state
        lifetime = StreamLifetime(state: state)
    }

    public static func makeStream(
        limits: BoneEventBufferLimits = .init(),
        payloadSize: @escaping @Sendable (Element) -> Int
    ) -> (stream: Self, producer: Producer) {
        let state = State(limits: limits, payloadSize: payloadSize)
        return (Self(state: state), Producer(state: state))
    }

    public var bufferSnapshot: BoneEventBufferSnapshot { state.snapshot() }

    public func makeAsyncIterator() -> AsyncIterator {
        // Keep the stream owner alive until its responsibility has passed to the lease.
        defer { withExtendedLifetime(lifetime) {} }
        return AsyncIterator(lease: state.claimConsumer() ? IteratorLease(state: state) : nil)
    }

    fileprivate final class StreamLifetime: @unchecked Sendable {
        let state: State

        init(state: State) { self.state = state }

        deinit { state.releaseStream() }
    }

    fileprivate final class IteratorLease: @unchecked Sendable {
        let state: State

        init(state: State) { self.state = state }

        func next() async throws -> Element? {
            // Iterator copies share this lease, including while a next call is suspended.
            defer { withExtendedLifetime(self) {} }
            return try await state.next()
        }

        deinit { state.releaseIterator() }
    }

    fileprivate final class State: @unchecked Sendable {
        private struct Entry {
            let element: Element
            let size: Int
        }

        /// Nil consumed slots release payloads immediately; compaction is amortized O(1).
        private struct FIFO<Value> {
            private var storage: [Value?] = []
            private var head = 0

            var count: Int { storage.count - head }
            var isEmpty: Bool { count == 0 }
            var first: Value? { isEmpty ? nil : storage[head] }

            mutating func append(_ value: Value) { storage.append(value) }

            mutating func popFirst() -> Value? {
                guard !isEmpty else { return nil }
                let value = storage[head]
                storage[head] = nil
                head += 1
                if head == storage.count {
                    storage.removeAll(keepingCapacity: true)
                    head = 0
                } else if head >= 64, head >= storage.count - head {
                    storage.removeFirst(head)
                    head = 0
                }
                return value
            }

            mutating func takeAll() -> [Value?] {
                let previous = storage
                storage = []
                head = 0
                return previous
            }
        }

        private enum Status {
            case open
            case finished
            case failed(Error)
            case cancelled
        }

        // All mutable operation fields are protected by State.lock, including the race
        // where cancellation arrives before the continuation has been registered.
        private final class SendOperation: @unchecked Sendable {
            var cancelled = false
            var completed = false
            var entry: Entry?
            var continuation: CheckedContinuation<Void, Error>?
        }

        private final class NextOperation {
            var continuation: CheckedContinuation<Element?, Error>?
        }

        private typealias Handler = @Sendable (Termination) -> Void

        private struct Effects {
            var sends: [(CheckedContinuation<Void, Error>, Result<Void, Error>)] = []
            var receives: [(CheckedContinuation<Element?, Error>, Result<Element?, Error>)] = []
            var notification: (Handler, Termination)?
            // Release arbitrary payloads and replaced closures only after unlocking.
            var retiredEntries: [Entry] = []
            var retiredQueue: [Entry?] = []
            var retiredHandler: Handler?

            func run() {
                for (continuation, result) in sends { continuation.resume(with: result) }
                for (continuation, result) in receives { continuation.resume(with: result) }
                if let (handler, termination) = notification { handler(termination) }
                withExtendedLifetime(retiredEntries) {}
                withExtendedLifetime(retiredQueue) {}
                withExtendedLifetime(retiredHandler) {}
            }
        }

        private let lock = NSLock()
        private let limits: BoneEventBufferLimits
        private let payloadSize: @Sendable (Element) -> Int
        private var status: Status = .open
        private var queue = FIFO<Entry>()
        private var pendingSends = FIFO<SendOperation>()
        private var queuedBytes = 0
        private var peakCount = 0
        private var peakBytes = 0
        private var consumerClaimed = false
        private var consumerExhausted = false
        private var activeNext: NextOperation?
        private var termination: Termination?
        private var handler: Handler?
        private var handlerInvoked = false

        init(limits: BoneEventBufferLimits, payloadSize: @escaping @Sendable (Element) -> Int) {
            self.limits = limits
            self.payloadSize = payloadSize
        }

        func snapshot() -> BoneEventBufferSnapshot {
            lock.lock()
            let snapshot = BoneEventBufferSnapshot(
                bufferedEventCount: queue.count,
                bufferedPayloadBytes: queuedBytes,
                peakBufferedEventCount: peakCount,
                peakBufferedPayloadBytes: peakBytes
            )
            lock.unlock()
            return snapshot
        }

        func claimConsumer() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !consumerClaimed else { return false }
            consumerClaimed = true
            return true
        }

        func releaseStream() {
            var effects = Effects()
            lock.lock()
            if !consumerClaimed { cancelLocked(effects: &effects) }
            lock.unlock()
            effects.run()
        }

        func releaseIterator() {
            var effects = Effects()
            lock.lock()
            if !consumerExhausted { cancelLocked(effects: &effects) }
            lock.unlock()
            effects.run()
        }

        func send(_ element: Element) async throws {
            let operation = SendOperation()
            try await withTaskCancellationHandler {
                let size = payloadSize(element)
                try await withCheckedThrowingContinuation { continuation in
                    registerSend(element, size: size, operation: operation,
                                 continuation: continuation, taskCancelled: Task.isCancelled)
                }
            } onCancel: {
                self.cancelSend(operation)
            }
        }

        private func registerSend(
            _ element: Element,
            size: Int,
            operation: SendOperation,
            continuation: CheckedContinuation<Void, Error>,
            taskCancelled: Bool
        ) {
            var effects = Effects()
            lock.lock()
            operation.continuation = continuation
            if operation.cancelled || taskCancelled {
                completeSendLocked(operation, result: .failure(CancellationError()), effects: &effects)
            } else if let error = sendErrorLocked() {
                completeSendLocked(operation, result: .failure(error), effects: &effects)
            } else if let error = payloadError(size) {
                finishLocked(throwing: error, effects: &effects)
                completeSendLocked(operation, result: .failure(error), effects: &effects)
            } else {
                let entry = Entry(element: element, size: size)
                if pendingSends.isEmpty, hasCapacityLocked(size) {
                    acceptLocked(entry, effects: &effects)
                    completeSendLocked(operation, result: .success(()), effects: &effects)
                } else {
                    operation.entry = entry
                    pendingSends.append(operation)
                }
            }
            lock.unlock()
            effects.run()
        }

        private func cancelSend(_ operation: SendOperation) {
            var effects = Effects()
            lock.lock()
            if !operation.completed {
                operation.cancelled = true
                if operation.continuation != nil {
                    completeSendLocked(operation, result: .failure(CancellationError()), effects: &effects)
                    admitPendingLocked(effects: &effects)
                }
            }
            lock.unlock()
            effects.run()
        }

        func offer(_ element: Element) -> OfferResult {
            // User code, like the termination handler, never runs under the state lock.
            let size = payloadSize(element)
            var effects = Effects()
            let result: OfferResult
            lock.lock()
            if sendErrorLocked() != nil {
                result = .terminated
            } else if let error = payloadError(size) {
                finishLocked(throwing: error, effects: &effects)
                result = .failed(error)
            } else if !pendingSends.isEmpty || !hasCapacityLocked(size) {
                finishLocked(throwing: BoneEventStreamError.bufferOverflow, effects: &effects)
                result = .failed(.bufferOverflow)
            } else {
                acceptLocked(Entry(element: element, size: size), effects: &effects)
                result = .accepted
            }
            lock.unlock()
            effects.run()
            return result
        }

        func next() async throws -> Element? {
            let operation = NextOperation()
            // Refuse overlapping calls before installing a cancellation handler, so misuse
            // by a second call cannot cancel the legitimate pending next call.
            try beginNext(operation)
            defer { endNext(operation) }
            do {
                let element: Element? = try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        registerNext(operation, continuation: continuation, taskCancelled: Task.isCancelled)
                    }
                } onCancel: {
                    self.cancelConsumer()
                }
                if Task.isCancelled {
                    cancelConsumer()
                    throw CancellationError()
                }
                return element
            } catch {
                if Task.isCancelled {
                    cancelConsumer()
                    throw CancellationError()
                }
                throw error
            }
        }

        private func beginNext(_ operation: NextOperation) throws {
            lock.lock()
            defer { lock.unlock() }
            guard activeNext == nil else { throw BoneEventStreamError.multipleConsumers }
            activeNext = operation
        }

        private func endNext(_ operation: NextOperation) {
            lock.lock()
            if activeNext === operation { activeNext = nil }
            lock.unlock()
        }

        private func registerNext(
            _ operation: NextOperation,
            continuation: CheckedContinuation<Element?, Error>,
            taskCancelled: Bool
        ) {
            var effects = Effects()
            lock.lock()
            if taskCancelled { cancelLocked(effects: &effects) }
            if case .cancelled = status {
                consumerExhausted = true
                effects.receives.append((continuation, .failure(CancellationError())))
            } else if let entry = queue.popFirst() {
                queuedBytes -= entry.size
                effects.receives.append((continuation, .success(entry.element)))
                admitPendingLocked(effects: &effects)
            } else {
                switch status {
                case .open:
                    operation.continuation = continuation
                case .finished:
                    consumerExhausted = true
                    effects.receives.append((continuation, .success(nil)))
                case .failed(let error):
                    consumerExhausted = true
                    effects.receives.append((continuation, .failure(error)))
                case .cancelled:
                    preconditionFailure("Cancellation was handled before dequeuing")
                }
            }
            lock.unlock()
            effects.run()
        }

        func finish(throwing error: Error?) {
            var effects = Effects()
            lock.lock()
            finishLocked(throwing: error, effects: &effects)
            lock.unlock()
            effects.run()
        }

        func onTermination(_ newHandler: @escaping @Sendable (Termination) -> Void) {
            var effects = Effects()
            lock.lock()
            if !handlerInvoked {
                if let termination {
                    handlerInvoked = true
                    effects.notification = (newHandler, termination)
                } else {
                    effects.retiredHandler = handler
                    handler = newHandler
                }
            }
            lock.unlock()
            effects.run()
        }

        private func cancelConsumer() {
            var effects = Effects()
            lock.lock()
            cancelLocked(effects: &effects)
            lock.unlock()
            effects.run()
        }

        private func payloadError(_ size: Int) -> BoneEventStreamError? {
            if size < 0 { return .invalidPayloadSize }
            if size > limits.maximumEventPayloadBytes { return .eventTooLarge }
            return nil
        }

        private func sendErrorLocked() -> Error? {
            switch status {
            case .open: return nil
            case .finished: return BoneEventStreamError.terminated
            case .failed(let error): return error
            case .cancelled: return CancellationError()
            }
        }

        private func hasCapacityLocked(_ size: Int) -> Bool {
            // Subtraction avoids overflowing for valid limits as large as Int.max.
            queue.count < limits.maximumEventCount && size <= limits.maximumQueuedPayloadBytes - queuedBytes
        }

        private func acceptLocked(_ entry: Entry, effects: inout Effects) {
            if let continuation = activeNext?.continuation {
                activeNext?.continuation = nil
                effects.receives.append((continuation, .success(entry.element)))
            } else {
                queue.append(entry)
                queuedBytes += entry.size
                peakCount = Swift.max(peakCount, queue.count)
                peakBytes = Swift.max(peakBytes, queuedBytes)
            }
        }

        private func completeSendLocked(
            _ operation: SendOperation,
            result: Result<Void, Error>,
            effects: inout Effects
        ) {
            operation.completed = true
            if let entry = operation.entry {
                effects.retiredEntries.append(entry)
                operation.entry = nil
            }
            if let continuation = operation.continuation {
                operation.continuation = nil
                effects.sends.append((continuation, result))
            }
        }

        private func admitPendingLocked(effects: inout Effects) {
            guard case .open = status else { return }
            while let operation = pendingSends.first {
                if operation.completed {
                    _ = pendingSends.popFirst()
                    continue
                }
                guard let entry = operation.entry, hasCapacityLocked(entry.size) else { break }
                _ = pendingSends.popFirst()
                acceptLocked(entry, effects: &effects)
                completeSendLocked(operation, result: .success(()), effects: &effects)
            }
        }

        private func finishLocked(throwing error: Error?, effects: inout Effects) {
            guard case .open = status else { return }
            status = error.map(Status.failed) ?? .finished
            notifyLocked(error == nil ? .finished : .failed, effects: &effects)
            let sendError = error ?? BoneEventStreamError.terminated
            while let operation = pendingSends.popFirst() {
                if !operation.completed {
                    completeSendLocked(operation, result: .failure(sendError), effects: &effects)
                }
            }
            if let continuation = activeNext?.continuation {
                activeNext?.continuation = nil
                consumerExhausted = true
                effects.receives.append((continuation, error.map { .failure($0) } ?? .success(nil)))
            }
        }

        private func cancelLocked(effects: inout Effects) {
            guard !consumerExhausted else { return }
            status = .cancelled
            consumerExhausted = true
            effects.retiredQueue = queue.takeAll()
            queuedBytes = 0
            notifyLocked(.cancelled, effects: &effects)
            while let operation = pendingSends.popFirst() {
                if !operation.completed {
                    completeSendLocked(operation, result: .failure(CancellationError()), effects: &effects)
                }
            }
            if let continuation = activeNext?.continuation {
                activeNext?.continuation = nil
                effects.receives.append((continuation, .failure(CancellationError())))
            }
        }

        private func notifyLocked(_ reason: Termination, effects: inout Effects) {
            guard termination == nil else { return }
            termination = reason
            if let handler, !handlerInvoked {
                handlerInvoked = true
                effects.notification = (handler, reason)
                self.handler = nil
            }
        }
    }
}
