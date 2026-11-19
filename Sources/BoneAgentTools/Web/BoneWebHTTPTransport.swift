import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BoneWebHTTPResponse: Sendable {
    public let url: URL
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(url: URL, statusCode: Int, headers: [String: String] = [:], body: Data) {
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Host implementations must bound bytes while receiving, propagate cancellation,
/// issue one request without retries, and refuse redirects/authentication replay.
/// Destination IP/DNS restrictions belong to the host network layer.
public protocol BoneWebHTTPTransport: Sendable {
    func send(request: URLRequest, maximumResponseBytes: Int) async throws -> BoneWebHTTPResponse
}

/// An ephemeral, delegate-backed GET transport, available on iOS 13/macOS 13.
/// No cookies, credential storage, response cache, redirects or application retries.
public struct BoneURLSessionWebTransport: BoneWebHTTPTransport {
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration

    public init() { makeConfiguration = { .ephemeral } }

    // For offline URLProtocol tests; each call must return a fresh configuration.
    init(makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration) {
        self.makeConfiguration = makeConfiguration
    }

    public func send(request: URLRequest, maximumResponseBytes: Int) async throws -> BoneWebHTTPResponse {
        guard (1...BoneWebLimits.maximumPageResponseBytes).contains(maximumResponseBytes),
              request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url else { throw BoneWebError.invalidConfiguration }
        _ = try BoneWebValidation.publicHTTPSURL(url.absoluteString)
        let operation = BoneWebRequestOperation(maximumBytes: maximumResponseBytes)
        let response = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                operation.start(request: request, configuration: makeConfiguration(), continuation: continuation)
            }
        }, onCancel: {
            operation.cancel()
        })
        try Task.checkCancellation()
        return response
    }
}

/// All mutable state is protected by `lock`; callbacks and cancellation may race.
private final class BoneWebRequestOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<BoneWebHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false

    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<BoneWebHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<BoneWebHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let session = self.session
        let task = self.task
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.response = nil
        body.removeAll(keepingCapacity: false)
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
        finish(.failure(BoneWebError.redirectNotAllowed))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Default TLS certificate validation only; never replay a credential challenge.
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failure(BoneWebError.httpFailure))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.url != nil else {
            completionHandler(.cancel)
            finish(.failure(BoneWebError.invalidResponse))
            return
        }
        let failure: BoneWebError?
        if (300...399).contains(response.statusCode) { failure = .redirectNotAllowed }
        else if !(200...299).contains(response.statusCode) { failure = .httpFailure }
        else if response.expectedContentLength > Int64(maximumBytes) { failure = .responseTooLarge }
        else { failure = nil }
        if let failure {
            completionHandler(.cancel)
            finish(.failure(failure))
            return
        }
        lock.lock()
        let active = !finished
        if active { self.response = response }
        lock.unlock()
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard data.count <= maximumBytes - body.count else {
            lock.unlock()
            finish(.failure(BoneWebError.responseTooLarge))
            return
        }
        body.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure(boneWebSafeError(error)))
            return
        }
        lock.lock()
        guard !finished, let response, let url = response.url else {
            let active = !finished
            lock.unlock()
            if active { finish(.failure(BoneWebError.invalidResponse)) }
            return
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let result = BoneWebHTTPResponse(url: url, statusCode: response.statusCode, headers: headers, body: body)
        lock.unlock()
        finish(.success(result))
    }
}

func boneWebCheckResponse(_ response: BoneWebHTTPResponse, requestedURL: URL,
                          policy: BoneWebHostPolicy, maximumBytes: Int) throws {
    // Also enforce these constraints for injected transports, before parsing any bytes.
    guard response.url == requestedURL else { throw BoneWebError.redirectNotAllowed }
    _ = try policy.validate(url: response.url.absoluteString)
    guard !(300...399).contains(response.statusCode) else { throw BoneWebError.redirectNotAllowed }
    guard (200...299).contains(response.statusCode) else { throw BoneWebError.httpFailure }
    guard response.body.count <= maximumBytes else { throw BoneWebError.responseTooLarge }
}
