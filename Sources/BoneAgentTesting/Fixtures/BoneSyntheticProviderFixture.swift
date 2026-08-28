import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import BoneAgentKit

public enum BoneSyntheticProviderFixtureError: Error, Equatable, Sendable {
    case nonSyntheticEndpoint
    case scriptExhausted
}

public struct BoneSyntheticHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, data: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

public struct BoneSafeHTTPRequestSnapshot: Encodable, Equatable, Sendable {
    public let method: String
    public let scheme: String
    public let host: String
    public let path: String
    public let headerNames: [String]
    public let requestBodyByteCount: Int
    public let responseStatusCode: Int
    public let responseBodyByteCount: Int
    public let streaming: Bool

    init(
        method: String,
        scheme: String,
        host: String,
        path: String,
        headerNames: [String],
        requestBodyByteCount: Int,
        responseStatusCode: Int,
        responseBodyByteCount: Int,
        streaming: Bool
    ) {
        self.method = method
        self.scheme = scheme
        self.host = host
        self.path = path
        self.headerNames = headerNames
        self.requestBodyByteCount = requestBodyByteCount
        self.responseStatusCode = responseStatusCode
        self.responseBodyByteCount = responseBodyByteCount
        self.streaming = streaming
    }
}

public actor BoneSafeHTTPRecorder {
    private var values: [BoneSafeHTTPRequestSnapshot] = []

    public init() {}
    func record(_ snapshot: BoneSafeHTTPRequestSnapshot) { values.append(snapshot) }
    public func snapshots() -> [BoneSafeHTTPRequestSnapshot] { values }
}

public struct BoneSyntheticProviderFixture: Sendable {
    public let transport: BoneRecordingHTTPTransport
    public let recorder: BoneSafeHTTPRecorder

    public init(
        httpResponses: [BoneSyntheticHTTPResponse],
        eventStreams: [[BoneInferenceEventStreamEvent]] = []
    ) throws {
        let recorder = BoneSafeHTTPRecorder()
        self.recorder = recorder
        transport = BoneRecordingHTTPTransport(
            httpResponses: httpResponses,
            eventStreams: eventStreams,
            recorder: recorder
        )
    }
}

public actor BoneRecordingHTTPTransport: BoneInferenceHTTPTransport {
    private static let allowedRequestHeaderNames: Set<String> = [
        "accept", "content-type", "x-request-id", "x-client-version"
    ]
    private var httpResponses: [BoneSyntheticHTTPResponse]
    private var eventStreams: [[BoneInferenceEventStreamEvent]]
    private let recorder: BoneSafeHTTPRecorder

    init(
        httpResponses: [BoneSyntheticHTTPResponse],
        eventStreams: [[BoneInferenceEventStreamEvent]],
        recorder: BoneSafeHTTPRecorder
    ) {
        self.httpResponses = httpResponses
        self.eventStreams = eventStreams
        self.recorder = recorder
    }

    public func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try validate(request)
        guard !httpResponses.isEmpty else { throw BoneSyntheticProviderFixtureError.scriptExhausted }
        let scripted = httpResponses.removeFirst()
        await recorder.record(snapshot(
            request: request,
            statusCode: scripted.statusCode,
            responseByteCount: scripted.data.count,
            streaming: false
        ))
        return .init(statusCode: scripted.statusCode, data: scripted.data, headers: scripted.headers)
    }

    public func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    public func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        try validate(request)
        guard !eventStreams.isEmpty else { throw BoneSyntheticProviderFixtureError.scriptExhausted }
        let events = eventStreams.removeFirst()
        let responseByteCount = events.reduce(0) { $0 + $1.data.utf8.count }
        guard responseByteCount <= options.maximumBytes else {
            throw BoneInferenceTransportError.responseTooLarge
        }
        await recorder.record(snapshot(
            request: request,
            statusCode: 200,
            responseByteCount: responseByteCount,
            streaming: true
        ))
        return .init(statusCode: 200, events: events)
    }

    private func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "synthetic.invalid" else {
            throw BoneSyntheticProviderFixtureError.nonSyntheticEndpoint
        }
    }

    private func snapshot(
        request: URLRequest,
        statusCode: Int,
        responseByteCount: Int,
        streaming: Bool
    ) -> BoneSafeHTTPRequestSnapshot {
        let url = request.url
        let headerNames = (request.allHTTPHeaderFields ?? [:]).keys
            .map { $0.lowercased() }
            .filter(Self.allowedRequestHeaderNames.contains)
            .sorted()
        return .init(
            method: request.httpMethod ?? "GET",
            scheme: url?.scheme?.lowercased() ?? "",
            host: url?.host?.lowercased() ?? "",
            path: url?.path ?? "",
            headerNames: headerNames,
            requestBodyByteCount: request.httpBody?.count ?? 0,
            responseStatusCode: statusCode,
            responseBodyByteCount: responseByteCount,
            streaming: streaming
        )
    }
}
