import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class BoneURLSessionLocalModelDownloadTransport: @unchecked Sendable,
    BoneLocalModelDownloadTransport {
    private let configuration: URLSessionConfiguration

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
    }

    public func start(
        _ request: BoneLocalModelDownloadRequest
    ) async throws -> any BoneLocalModelDownloadOperation {
        try BoneLocalModelDownloadSecurityPolicy.validate(request.source.url, for: request.source)
        return BoneURLSessionLocalModelDownloadOperation(
            request: request,
            configuration: configuration
        )
    }
}

private final class BoneURLSessionLocalModelDownloadOperation: NSObject, @unchecked Sendable,
    BoneLocalModelDownloadOperation, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let request: BoneLocalModelDownloadRequest
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.Continuation?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var started = false
    private var terminal = false

    init(request: BoneLocalModelDownloadRequest, configuration: URLSessionConfiguration) {
        self.request = request
        self.configuration = configuration.copy() as? URLSessionConfiguration ?? configuration
        super.init()
    }

    func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            let shouldStart = !started && !terminal
            if shouldStart { self.continuation = continuation }
            started = true
            lock.unlock()
            guard shouldStart else {
                continuation.finish(throwing: BoneLocalModelDownloadTransportFailure.other)
                return
            }
            continuation.onTermination = { [weak self] _ in self?.stop() }
            startSession()
        }
    }

    func pause() async throws -> Data {
        guard let task = lockedTask() else {
            throw BoneLocalModelDownloadError.resumeDataUnavailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            task.cancel { data in
                guard let data else {
                    continuation.resume(throwing: BoneLocalModelDownloadError.resumeDataUnavailable)
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    func cancel() async { stop() }

    private func stop() { finish(throwing: .cancelled(resumeData: nil)) }

    private func startSession() {
        let config = configuration.copy() as? URLSessionConfiguration ?? configuration
        config.allowsCellularAccess = request.policy.allowsCellularAccess
        config.timeoutIntervalForRequest = request.policy.requestTimeoutSeconds
        config.timeoutIntervalForResource = request.policy.resourceTimeoutSeconds
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task: URLSessionDownloadTask
        if let resumeData = request.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var urlRequest = URLRequest(url: request.source.url)
            urlRequest.timeoutInterval = request.policy.requestTimeoutSeconds
            urlRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            task = session.downloadTask(with: urlRequest)
        }
        lock.lock()
        guard !terminal else {
            lock.unlock()
            task.cancel()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        self.task = task
        task.resume()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= request.expectedByteCount,
              totalBytesExpectedToWrite <= request.expectedByteCount else {
            finish(throwing: .invalidResponse(statusCode: nil))
            return
        }
        yield(.progress(.init(downloadedBytes: totalBytesWritten, expectedBytes: request.expectedByteCount)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64
    ) {
        guard fileOffset <= request.expectedByteCount, expectedTotalBytes <= request.expectedByteCount else {
            finish(throwing: .invalidResponse(statusCode: nil))
            return
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let isTerminal = terminal
        lock.unlock()
        guard !isTerminal else { return }
        guard let response = downloadTask.response as? HTTPURLResponse else {
            finish(throwing: .invalidResponse(statusCode: nil))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            let failure: BoneLocalModelDownloadTransportFailure = response.statusCode >= 500
                ? .server(statusCode: response.statusCode)
                : .client(statusCode: response.statusCode)
            finish(throwing: failure)
            return
        }
        do {
            if let finalURL = response.url {
                try BoneLocalModelDownloadSecurityPolicy.validate(finalURL, for: request.source)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value <= request.expectedByteCount else {
                finish(throwing: .invalidResponse(statusCode: nil))
                return
            }
            try FileManager.default.createDirectory(
                at: request.destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Serialize publication with cancellation: after cancel returns no late move
            // may recreate a destination that the coordinator has already cleaned.
            lock.lock()
            guard !terminal else { lock.unlock(); return }
            do {
                try FileManager.default.moveItem(at: location, to: request.destinationURL)
            } catch { lock.unlock(); throw error }
            continuation?.yield(.completed(request.destinationURL))
            lock.unlock()
            finish()
        } catch let error as BoneLocalModelDownloadError {
            finish(throwing: error == .untrustedURL ? .untrustedRedirect : .other)
        } catch {
            finish(throwing: .other)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest redirectRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = redirectRequest.url,
              (try? BoneLocalModelDownloadSecurityPolicy.validate(url, for: request.source)) != nil else {
            completionHandler(nil)
            finish(throwing: .untrustedRedirect)
            return
        }
        completionHandler(redirectRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        if let urlError = error as? URLError {
            let resumeData = (urlError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
            switch urlError.code {
            case .cancelled:
                finish(throwing: .cancelled(resumeData: resumeData))
            case .timedOut:
                finish(throwing: .timedOut)
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                finish(throwing: .networkUnavailable)
            default:
                finish(throwing: .other)
            }
        } else {
            finish(throwing: .other)
        }
    }

    private func lockedTask() -> URLSessionDownloadTask? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    private func yield(_ event: BoneLocalModelDownloadTransportEvent) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.yield(event)
    }

    private func finish(throwing failure: BoneLocalModelDownloadTransportFailure? = nil) {
        lock.lock()
        guard !terminal else { lock.unlock(); return }
        terminal = true
        let continuation = continuation
        self.continuation = nil
        let task = task
        self.task = nil
        let session = session
        self.session = nil
        lock.unlock()
        if let failure {
            task?.cancel()
            session?.invalidateAndCancel()
            continuation?.finish(throwing: failure)
        } else {
            continuation?.finish()
        }
        session?.finishTasksAndInvalidate()
    }
}
