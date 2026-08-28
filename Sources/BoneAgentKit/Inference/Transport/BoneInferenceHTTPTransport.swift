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

public protocol BoneInferenceHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse
    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse
}
