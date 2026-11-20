import Foundation
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Fixed-endpoint POST transport for the Host's DeepSeek Search adapter.
/// Bounded receiving, no redirects, cookies, credential replay, caching or retries.
struct DemoSearchPOSTTransport: BoneWebHTTPTransport {
    private let configuration: @Sendable () -> URLSessionConfiguration
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration = { .ephemeral }) { self.configuration = configuration }

    func send(request: URLRequest, maximumResponseBytes: Int) async throws -> BoneWebHTTPResponse {
        guard request.httpMethod == "POST", request.url?.absoluteString == "https://api.deepseek.com/v1/tools/search",
              let body = request.httpBody, body.count <= 4_096, request.httpBodyStream == nil,
              (1...1_048_576).contains(maximumResponseBytes) else { throw BoneWebError.invalidConfiguration }
        let operation = DemoSearchPOSTOperation(maximumBytes: maximumResponseBytes)
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start(request, configuration: configuration(), continuation: $0) }
        } onCancel: { operation.cancel() }
        try Task.checkCancellation()
        return result
    }
}

private final class DemoSearchPOSTOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var continuation: CheckedContinuation<BoneWebHTTPResponse, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var finished = false
    init(maximumBytes: Int) { self.maximumBytes = maximumBytes }

    func start(_ request: URLRequest, configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<BoneWebHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = request
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        lock.unlock()
        task.resume()
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func finish(_ result: Result<BoneWebHTTPResponse, any Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation, session = self.session, task = self.task
        self.continuation = nil; self.session = nil; self.task = nil; self.response = nil; data.removeAll()
        lock.unlock()
        task?.cancel(); session?.invalidateAndCancel(); continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil); finish(.failure(BoneWebError.redirectNotAllowed))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == "NSURLAuthenticationMethodServerTrust" { completionHandler(.performDefaultHandling, nil) }
        else { completionHandler(.cancelAuthenticationChallenge, nil); finish(.failure(BoneWebError.httpFailure)) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(BoneWebError.invalidResponse)); return }
        guard response.url?.absoluteString == "https://api.deepseek.com/v1/tools/search" else {
            completionHandler(.cancel); finish(.failure(BoneWebError.redirectNotAllowed)); return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); finish(.failure(BoneWebError.responseTooLarge)); return
        }
        lock.lock(); self.response = response; lock.unlock()
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        guard chunk.count <= maximumBytes - data.count else { lock.unlock(); finish(.failure(BoneWebError.responseTooLarge)); return }
        data.append(chunk); lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            finish(.failure((error as? URLError)?.code == .cancelled ? CancellationError() : BoneWebError.requestFailed))
            return
        }
        lock.lock()
        let response = self.response, body = data
        lock.unlock()
        guard let response, let url = response.url else { finish(.failure(BoneWebError.invalidResponse)); return }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields { if let key = key as? String, let value = value as? String { headers[key] = value } }
        finish(.success(.init(url: url, statusCode: response.statusCode, headers: headers, body: body)))
    }
}
