import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 单请求非流式 URLSession bridge，在下载期间执行容量限制并采集安全 metrics。
final class BoneInferenceHTTPSessionBridge: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private let failureCapture: BoneInferenceFailureCapture
    private let captureID = UUID()
    private var failureBody = Data()
    private var failureBodyTruncated = false
    private let maximumBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var metrics: URLSessionTaskMetrics?
    private var continuation: CheckedContinuation<(Data, BoneInferenceHTTPResponseMetadata), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var explicitlyCancelled = false
    private let startedAt = Date()

    init(configuration: URLSessionConfiguration, request: URLRequest, maximumBytes: Int, failureCapture: BoneInferenceFailureCapture = .init()) {
        self.failureCapture = failureCapture
        self.configuration = configuration
        self.request = request
        self.maximumBytes = max(0, maximumBytes)
    }

    func start() async throws -> (Data, BoneInferenceHTTPResponseMetadata) {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !completed else {
                lock.unlock()
                continuation.resume(throwing: BoneInferenceTransportError.cancelled)
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            let task = session.dataTask(with: request)
            self.session = session
            self.task = task
            lock.unlock()
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
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard BoneInferenceRedirectPolicy.allows(from: request.url, to: newRequest.url) else {
            completionHandler(nil)
            finish(.failure(BoneInferenceTransportError.invalidEndpoint), cancelTask: true)
            return
        }
        completionHandler(newRequest)
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
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if failureCapture.isEnabled, let response, !(200...299).contains(response.statusCode) {
            let remaining = failureCapture.maximumBodyBytes - failureBody.count
            failureBody.append(chunk.prefix(remaining))
            if chunk.count > remaining { failureBodyTruncated = true }
        }
        guard chunk.count <= maximumBytes - data.count else {
            lock.unlock()
            finish(.failure(BoneInferenceTransportError.responseTooLarge), cancelTask: true)
            return
        }
        data.append(chunk)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            lock.lock()
            let cancelled = explicitlyCancelled
            lock.unlock()
            if cancelled || (error as? URLError)?.code == .cancelled {
                finish(.failure(BoneInferenceTransportError.cancelled), cancelTask: false)
            } else {
                let nsError = error as NSError
                lock.lock()
                let safeMetrics = Self.snapshot(metrics: metrics, startedAt: startedAt)
                lock.unlock()
                finish(
                    .failure(BoneInferenceTransportError.network(.init(error: nsError, metrics: safeMetrics))),
                    cancelTask: false
                )
            }
            return
        }
        lock.lock()
        guard let response else {
            lock.unlock()
            finish(.failure(BoneInferenceTransportError.invalidResponse), cancelTask: false)
            return
        }
        let result = (
            data,
            BoneInferenceHTTPResponseMetadata(
                statusCode: response.statusCode,
                headers: Self.headers(from: response),
                metrics: Self.snapshot(metrics: metrics, startedAt: startedAt)
            )
        )
        lock.unlock()
        finish(.success(result), cancelTask: false, captureCompletion: .complete)
    }

    private func finish(
        _ result: Result<(Data, BoneInferenceHTTPResponseMetadata), Error>,
        cancelTask: Bool,
        captureCompletion: BoneInferenceFailureResponse.Completion = .interrupted
    ) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        let task = self.task
        let session = self.session
        let response = self.response
        let body = failureBody
        failureBody = Data()
        let completion: BoneInferenceFailureResponse.Completion = failureBodyTruncated ? .byteLimit : captureCompletion
        lock.unlock()
        if cancelTask { task?.cancel() }
        session?.finishTasksAndInvalidate()
        if let response, failureCapture.isEnabled {
            failureCapture.emit(id: captureID, statusCode: response.statusCode, headers: Self.headers(from: response),
                                body: body, completion: completion)
        }
        continuation?.resume(with: result)
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { result, item in
            result[String(describing: item.key)] = String(describing: item.value)
        }
    }

    private static func snapshot(metrics: URLSessionTaskMetrics?, startedAt: Date) -> BoneInferenceHTTPMetrics {
        guard let transaction = metrics?.transactionMetrics.last else {
            return .init(totalDuration: max(0, Date().timeIntervalSince(startedAt)))
        }
        return .init(
            dnsDuration: interval(transaction.domainLookupStartDate, transaction.domainLookupEndDate),
            connectDuration: interval(transaction.connectStartDate, transaction.connectEndDate),
            tlsDuration: interval(transaction.secureConnectionStartDate, transaction.secureConnectionEndDate),
            requestDuration: interval(transaction.requestStartDate, transaction.requestEndDate),
            firstByteDuration: interval(transaction.requestEndDate, transaction.responseStartDate),
            totalDuration: metrics.map { max(0, $0.taskInterval.duration) }
                ?? max(0, Date().timeIntervalSince(startedAt)),
            networkProtocolName: transaction.networkProtocolName
        )
    }

    private static func interval(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}
