import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 一个已由空行终止的 Server-Sent Event。原始 data 只供当前请求解析，不可普通持久化。
public struct BoneInferenceEventStreamEvent: Equatable, Sendable {
    public let event: String?
    public let id: String?
    public let data: String

    public init(event: String? = nil, id: String? = nil, data: String) {
        self.event = event
        self.id = id
        self.data = data
    }
}

/// 按字节增量解析 SSE，并对整条流实施容量边界。
public struct BoneInferenceEventStreamFramer: Sendable {
    private let maximumBytes: Int
    private var receivedBytes = 0
    private var buffer = Data()
    private var eventName: String?
    private var eventID: String?
    private var dataLines: [String] = []
    private var hasFields = false

    public init(maximumBytes: Int) {
        self.maximumBytes = max(0, maximumBytes)
    }

    public mutating func append(_ chunk: Data) throws -> [BoneInferenceEventStreamEvent] {
        guard chunk.count <= maximumBytes - receivedBytes else {
            throw BoneInferenceTransportError.responseTooLarge
        }
        receivedBytes += chunk.count
        buffer.append(chunk)
        var events: [BoneInferenceEventStreamEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw BoneInferenceTransportError.invalidResponse
            }
            if let event = consume(line: line) { events.append(event) }
        }
        return events
    }

    public mutating func finish() throws -> [BoneInferenceEventStreamEvent] {
        if !buffer.isEmpty {
            var lineData = buffer[...]
            buffer.removeAll(keepingCapacity: false)
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            guard let line = String(data: lineData, encoding: .utf8) else {
                throw BoneInferenceTransportError.invalidResponse
            }
            _ = consume(line: line)
        }
        guard hasFields else { return [] }
        guard !dataLines.isEmpty else {
            eventName = nil
            eventID = nil
            hasFields = false
            return []
        }
        let event = BoneInferenceEventStreamEvent(
            event: eventName,
            id: eventID,
            data: dataLines.joined(separator: "\n")
        )
        eventName = nil
        eventID = nil
        dataLines.removeAll(keepingCapacity: true)
        hasFields = false
        return [event]
    }

    private mutating func consume(line: String) -> BoneInferenceEventStreamEvent? {
        if line.isEmpty {
            guard hasFields else { return nil }
            defer {
                eventName = nil
                eventID = nil
                dataLines.removeAll(keepingCapacity: true)
                hasFields = false
            }
            return BoneInferenceEventStreamEvent(
                event: eventName,
                id: eventID,
                data: dataLines.joined(separator: "\n")
            )
        }
        guard !line.hasPrefix(":") else { return nil }
        let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(pieces[0])
        var value = pieces.count == 2 ? String(pieces[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "event": eventName = value; hasFields = true
        case "id": eventID = value; hasFields = true
        case "data": dataLines.append(value); hasFields = true
        default: break
        }
        return nil
    }
}

/// 单请求 URLSession delegate bridge；仅在正常 EOF 且 Framer 完整时交付事件。
final class BoneInferenceEventStreamSessionBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let options: BoneInferenceEventStreamOptions
    private let lock = NSLock()
    private var framer: BoneInferenceEventStreamFramer
    private var events: [BoneInferenceEventStreamEvent] = []
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<BoneInferenceEventStreamResponse, Error>?
    private var eventContinuation: BoneInferenceRawEventStream.Continuation?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var watchdog: DispatchWorkItem?
    private var completed = false
    private var explicitlyCancelled = false

    init(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) {
        self.configuration = configuration
        self.request = request
        self.options = options
        framer = BoneInferenceEventStreamFramer(maximumBytes: options.maximumBytes)
    }

    func start() async throws -> BoneInferenceEventStreamResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !completed else {
                lock.unlock()
                continuation.resume(throwing: BoneInferenceTransportError.cancelled)
                return
            }
            self.continuation = continuation
            let streamConfiguration = configuration.copy() as! URLSessionConfiguration
            streamConfiguration.timeoutIntervalForRequest = .greatestFiniteMagnitude
            streamConfiguration.timeoutIntervalForResource = .greatestFiniteMagnitude
            let session = URLSession(configuration: streamConfiguration, delegate: self, delegateQueue: nil)
            var streamRequest = request
            streamRequest.timeoutInterval = .greatestFiniteMagnitude
            let task = session.dataTask(with: streamRequest)
            self.session = session
            self.task = task
            scheduleWatchdogLocked(error: .firstEventTimedOut, duration: options.firstEventTimeout)
            lock.unlock()
            task.resume()
        }
    }

    func eventStream() -> BoneInferenceRawEventStream {
        AsyncThrowingStream { continuation in
            lock.lock()
            guard !completed, eventContinuation == nil, self.continuation == nil else {
                lock.unlock()
                continuation.finish(throwing: BoneInferenceTransportError.cancelled)
                return
            }
            eventContinuation = continuation
            let streamConfiguration = configuration.copy() as! URLSessionConfiguration
            streamConfiguration.timeoutIntervalForRequest = .greatestFiniteMagnitude
            streamConfiguration.timeoutIntervalForResource = .greatestFiniteMagnitude
            let session = URLSession(configuration: streamConfiguration, delegate: self, delegateQueue: nil)
            var streamRequest = request
            streamRequest.timeoutInterval = .greatestFiniteMagnitude
            let task = session.dataTask(with: streamRequest)
            self.session = session
            self.task = task
            scheduleWatchdogLocked(error: .firstEventTimedOut, duration: options.firstEventTimeout)
            lock.unlock()
            continuation.onTermination = { @Sendable [weak self] _ in self?.cancel() }
            task.resume()
        }
    }

    func cancel() {
        lock.lock()
        explicitlyCancelled = true
        lock.unlock()
        finish(.failure(BoneInferenceTransportError.cancelled), cancelTask: true)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(BoneInferenceTransportError.invalidResponse), cancelTask: true)
            return
        }
        lock.lock()
        self.response = http
        if !(200 ... 299).contains(http.statusCode) {
            lock.unlock()
            completionHandler(.cancel)
            finish(.failure(BoneInferenceTransportError.httpStatus(http.statusCode)), cancelTask: true)
            return
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        do {
            let framed = try framer.append(data)
            if !framed.isEmpty {
                events.append(contentsOf: framed)
                for event in framed { eventContinuation?.yield(event) }
                scheduleWatchdogLocked(error: .idleTimedOut, duration: options.idleTimeout)
            } else if !events.isEmpty, !data.isEmpty {
                scheduleWatchdogLocked(error: .idleTimedOut, duration: options.idleTimeout)
            }
            lock.unlock()
        } catch {
            lock.unlock()
            finish(.failure(error), cancelTask: true)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let mapped: BoneInferenceTransportError
            lock.lock()
            let wasCancelled = explicitlyCancelled
            lock.unlock()
            if wasCancelled || (error as? URLError)?.code == .cancelled {
                mapped = .cancelled
            } else {
                let nsError = error as NSError
                mapped = .network(.init(error: nsError))
            }
            finish(.failure(mapped), cancelTask: false)
            return
        }
        lock.lock()
        do {
            guard let response else {
                lock.unlock()
                finish(.failure(BoneInferenceTransportError.invalidResponse), cancelTask: false)
                return
            }
            if (200 ... 299).contains(response.statusCode) {
                let finalEvents = try framer.finish()
                events.append(contentsOf: finalEvents)
                for event in finalEvents { eventContinuation?.yield(event) }
            }
            let result = BoneInferenceEventStreamResponse(
                statusCode: response.statusCode,
                events: events,
                headers: Self.headers(from: response)
            )
            lock.unlock()
            finish(.success(result), cancelTask: false)
        } catch {
            lock.unlock()
            finish(.failure(error), cancelTask: false)
        }
    }

    private func scheduleWatchdogLocked(error: BoneInferenceTransportError, duration: TimeInterval) {
        watchdog?.cancel()
        let seconds = max(0, duration)
        guard seconds > 0 else { return }
        let item = DispatchWorkItem { [weak self] in self?.finish(.failure(error), cancelTask: true) }
        watchdog = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func finish(_ result: Result<BoneInferenceEventStreamResponse, Error>, cancelTask: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        watchdog?.cancel()
        let continuation = self.continuation
        self.continuation = nil
        let eventContinuation = self.eventContinuation
        self.eventContinuation = nil
        let task = self.task
        let session = self.session
        lock.unlock()
        if cancelTask { task?.cancel() }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
        switch result {
        case .success: eventContinuation?.finish()
        case let .failure(error): eventContinuation?.finish(throwing: error)
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
    }

}
