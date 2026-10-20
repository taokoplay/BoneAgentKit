import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BoneInferenceURLSessionTransport: BoneInferenceHTTPTransport {
    public typealias Loader = @Sendable (URLRequest) async throws -> (
        Data,
        BoneInferenceHTTPResponseMetadata
    )

    public static let defaultMaximumResponseByteCount = 8 * 1_024 * 1_024

    public typealias Sleeper = @Sendable (TimeInterval) async throws -> Void
    public typealias StreamLoader = @Sendable (
        URLRequest,
        BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse

    private let failureCapture: BoneInferenceFailureCapture
    private let maximumResponseByteCount: Int
    private let loaderIsURLSession: Bool
    private let loader: Loader
    private let sleeper: Sleeper
    private let streamLoader: StreamLoader
    private let urlSessionConfiguration: URLSessionConfiguration?
    private let streamLoaderIsURLSession: Bool

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        maximumResponseByteCount: Int = Self.defaultMaximumResponseByteCount,
        failureCapture: BoneInferenceFailureCapture = .init()
    ) {
        self.failureCapture = failureCapture
        self.maximumResponseByteCount = max(0, maximumResponseByteCount)
        self.loaderIsURLSession = true
        self.urlSessionConfiguration = configuration
        self.streamLoaderIsURLSession = true
        self.loader = { request in
                let bridge = BoneInferenceHTTPSessionBridge(
                    configuration: configuration,
                    request: request,
                    maximumBytes: maximumResponseByteCount,
                    failureCapture: failureCapture
                )
                return try await withTaskCancellationHandler {
                    try await bridge.start()
                } onCancel: {
                    bridge.cancel()
                }
            }
        self.sleeper = { duration in try await Self.sleep(seconds: duration) }
        self.streamLoader = { request, options in
                let bridge = BoneInferenceEventStreamSessionBridge(
                    configuration: configuration,
                    request: request,
                    options: options,
                    failureCapture: failureCapture
                )
                return try await withTaskCancellationHandler {
                    try await bridge.start()
                } onCancel: {
                    bridge.cancel()
                }
            }
    }

    public init(
        maximumResponseByteCount: Int = Self.defaultMaximumResponseByteCount,
        loader: @escaping Loader,
        sleeper: @escaping Sleeper = { duration in try await Self.sleep(seconds: duration) },
        streamLoader: @escaping StreamLoader = { _, _ in
            throw BoneInferenceTransportError.invalidConfiguration
        },
        failureCapture: BoneInferenceFailureCapture = .init()
    ) {
        self.failureCapture = failureCapture
        self.maximumResponseByteCount = max(0, maximumResponseByteCount)
        self.loaderIsURLSession = false
        self.loader = loader
        self.sleeper = sleeper
        self.streamLoader = streamLoader
        urlSessionConfiguration = nil
        streamLoaderIsURLSession = false
    }

    public init(
        maximumResponseByteCount: Int = Self.defaultMaximumResponseByteCount,
        streamLoader: @escaping StreamLoader,
        failureCapture: BoneInferenceFailureCapture = .init()
    ) {
        self.init(
            maximumResponseByteCount: maximumResponseByteCount,
            loader: { _ in throw BoneInferenceTransportError.invalidConfiguration },
            streamLoader: streamLoader,
            failureCapture: failureCapture
        )
    }

    private func compatibilityEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) -> BoneInferenceRawEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let response = try await sendEventStream(request, options: options)
                    guard (200...299).contains(response.statusCode) else {
                        throw BoneInferenceTransportError.httpStatus(response.statusCode)
                    }
                    for event in response.events { continuation.yield(event) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public static func sleep(seconds: TimeInterval) async throws {
        let bounded = min(max(0, seconds), 60)
        guard bounded > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(bounded * 1_000_000_000))
    }

    public func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        do {
            try Task.checkCancellation()
            let (data, metadata) = try await loader(request)
            try Task.checkCancellation()
            if !loaderIsURLSession, failureCapture.isEnabled {
                failureCapture.emit(id: UUID(), statusCode: metadata.statusCode, headers: metadata.headers,
                                    body: data, completion: .complete)
            }
            guard data.count <= maximumResponseByteCount else {
                throw BoneInferenceTransportError.responseTooLarge
            }
            return BoneInferenceHTTPResponse(
                statusCode: metadata.statusCode,
                data: data,
                headers: metadata.headers,
                metrics: metadata.metrics
            )
        } catch is CancellationError {
            throw BoneInferenceTransportError.cancelled
        } catch let error as BoneInferenceStreamDeadlineExceeded {
            throw error
        } catch let error as BoneInferenceTransportError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw BoneInferenceTransportError.cancelled
        } catch {
            let nsError = error as NSError
            throw BoneInferenceTransportError.network(.init(error: nsError))
        }
    }

    public func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        var attempt = 1
        while true {
            do {
                let response = try await send(request)
                guard BoneInferenceRetryPolicy.shouldRetry(
                    method: request.httpMethod ?? "GET",
                    attempt: attempt,
                    statusCode: response.statusCode,
                    networkCode: nil
                ) else {
                    return response
                }
                let retryAfter = response.headers.first {
                    $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
                }?.value
                try await sleeper(BoneInferenceRetryPolicy.retryDelay(headerValue: retryAfter))
            } catch let error as BoneInferenceStreamDeadlineExceeded {
                throw error
            } catch let error as BoneInferenceTransportError {
                let networkCode: Int?
                if case .network(let diagnostic) = error { networkCode = diagnostic.code } else { networkCode = nil }
                guard BoneInferenceRetryPolicy.shouldRetry(
                    method: request.httpMethod ?? "GET",
                    attempt: attempt,
                    statusCode: nil,
                    networkCode: networkCode
                ) else {
                    throw error
                }
                try await sleeper(0)
            }
            attempt += 1
        }
    }

    public func eventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) -> BoneInferenceRawEventStream {
        // 只有默认 URLSession loader 能保证到达即交付；注入 loader 使用协议默认兼容实现。
        guard streamLoaderIsURLSession else {
            return compatibilityEventStream(request, options: options)
        }
        let bridge = BoneInferenceEventStreamSessionBridge(
            configuration: urlSessionConfiguration!,
            request: request,
            options: options,
            failureCapture: failureCapture
        )
        return bridge.eventStream()
    }

    public func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        do {
            try Task.checkCancellation()
            let response = try await streamLoader(request, options)
            try Task.checkCancellation()
            return response
        } catch is CancellationError {
            throw BoneInferenceTransportError.cancelled
        } catch let error as BoneInferenceStreamDeadlineExceeded {
            throw error
        } catch let error as BoneInferenceTransportError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw BoneInferenceTransportError.cancelled
        } catch {
            let nsError = error as NSError
            throw BoneInferenceTransportError.network(.init(error: nsError))
        }
    }
}
