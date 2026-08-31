import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct BoneInferenceHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]
    public let metrics: BoneInferenceHTTPMetrics?

    public init(
        statusCode: Int,
        data: Data,
        headers: [String: String] = [:],
        metrics: BoneInferenceHTTPMetrics? = nil
    ) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
        self.metrics = metrics
    }
}

/// 供可注入 loader 使用的无正文 HTTP 元数据。
public struct BoneInferenceHTTPResponseMetadata: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let metrics: BoneInferenceHTTPMetrics?

    public init(
        statusCode: Int,
        headers: [String: String] = [:],
        metrics: BoneInferenceHTTPMetrics? = nil
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.metrics = metrics
    }
}

public struct BoneInferenceEventStreamResponse: Sendable {
    public let statusCode: Int
    public let events: [BoneInferenceEventStreamEvent]
    public let headers: [String: String]

    public init(
        statusCode: Int,
        events: [BoneInferenceEventStreamEvent],
        headers: [String: String] = [:]
    ) {
        self.statusCode = statusCode
        self.events = events
        self.headers = headers
    }
}

public typealias BoneInferenceRawEventStream = AsyncThrowingStream<BoneInferenceEventStreamEvent, Error>

public protocol BoneInferenceHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse
    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse
    /// 原始 SSE 到达即交付；取消消费者必须传播到网络任务。
    func eventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) -> BoneInferenceRawEventStream
}

public extension BoneInferenceHTTPTransport {
    /// 测试替身与旧 Transport 的兼容实现；真实 URLSession Transport 覆盖为逐事件交付。
    func eventStream(
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
                    for event in response.events {
                        try Task.checkCancellation()
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: BoneInferenceTransportError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
