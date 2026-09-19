import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

/// 完全离线的跨 Provider 环境矩阵。HTTP 错误体与凭据均为合成 canary。
final class SDKEnvironmentMatrixTests: XCTestCase {
    private enum Provider: CaseIterable {
        case openAI, anthropic, gemini
        var response: String {
            switch self {
            case .openAI: return #"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#
            case .anthropic: return #"{"content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn"}"#
            case .gemini: return #"{"candidates":[{"content":{"parts":[{"text":"ok"}]},"finishReason":"STOP"}]}"#
            }
        }
        func engine(_ transport: MatrixTransport, sink: BoneInferenceDiagnosticSink) -> any BoneInferenceEngine {
            let url = URL(string: "https://fixture.example/v1")!
            switch self {
            case .openAI: return BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "credential-canary", baseURL: url), transport: transport, diagnostics: sink)
            case .anthropic: return BoneAnthropicInferenceEngine(configuration: .init(kind: .anthropic, apiKey: "credential-canary", baseURL: url, authenticationMode: .anthropicDual), transport: transport, diagnostics: sink)
            case .gemini: return BoneGeminiInferenceEngine(configuration: .init(kind: .google, apiKey: "credential-canary", baseURL: url, authenticationMode: .googleAPIKey), transport: transport, diagnostics: sink)
            }
        }
    }
    private var request: BoneInferenceRequest {
        .init(modelID: "fixture", messages: [.init(role: .user, content: "request-canary")])
    }

    func testHealthyProvidersHaveOneAttemptOneResponseOneResult() async throws {
        for provider in Provider.allCases {
            let transport = MatrixTransport(body: provider.response)
            let events = MatrixRecorder()
            let result = try await provider.engine(transport, sink: events.sink).infer(request: request)
            XCTAssertEqual(result, .finish(.init(text: "ok")))
            XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .httpResponseReceived, .resultValidated])
            let sends = await transport.sends
            XCTAssertEqual(sends, 1)
            assertSafe(events.values)
        }
    }

    func testLengthTerminalsAreRejectedAcrossProviders() async throws {
        let bodies: [(Provider, String)] = [
            (.openAI, #"{"choices":[{"index":0,"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}]}"#),
            (.anthropic, #"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#),
            (.gemini, #"{"candidates":[{"content":{"parts":[{"text":"partial"}]},"finishReason":"MAX_TOKENS"}]}"#)
        ]
        for (provider, body) in bodies {
            let transport = MatrixTransport(body: body)
            let events = MatrixRecorder()
            do {
                _ = try await provider.engine(transport, sink: events.sink).infer(request: request)
                XCTFail("Expected outputTruncated")
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .outputTruncated) }
            XCTAssertEqual(events.values[1].response?.stop, .length)
            XCTAssertEqual(events.values.last?.phase, .responseValidationFailed)
            let sends = await transport.sends
            XCTAssertEqual(sends, 1)
        }
    }

    func testHTTPFailureMatrixPreservesErrorsAndNeverRetries() async throws {
        // 403 不是凭据错误：网关、WAF 或风控也会返回 403，只保留状态码供调用方判断。
        let failures: [(Int, BoneInferenceTransportError)] = [
            (401, .invalidCredential), (403, .httpStatus(403)), (402, .quotaExceeded),
            (404, .unsupportedModel), (429, .rateLimited), (503, .httpStatus(503))
        ]
        for provider in Provider.allCases {
            for (status, expected) in failures {
                let transport = MatrixTransport(status: status, body: #"{"error":{"message":"response-canary"}}"#)
                let events = MatrixRecorder()
                do {
                    _ = try await provider.engine(transport, sink: events.sink).infer(request: request)
                    XCTFail("Expected failure: \(provider) / \(status)")
                } catch { XCTAssertEqual(error as? BoneInferenceTransportError, expected) }
                XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .httpResponseReceived, .responseValidationFailed])
                XCTAssertEqual(events.values[1].response?.statusCode, status)
                XCTAssertEqual(events.values[1].response?.inputTokens, .unknown)
                let sends = await transport.sends
                XCTAssertEqual(sends, 1)
                assertSafe(events.values)
            }
        }
    }

    func testMalformedBodiesRemainFailuresWithDiagnosticsOnOrOff() async throws {
        for provider in Provider.allCases {
            for body in ["", "not-json-canary", "[]"] {
                for enabled in [false, true] {
                    let events = MatrixRecorder()
                    let transport = MatrixTransport(body: body)
                    do {
                        _ = try await provider.engine(transport, sink: enabled ? events.sink : .init()).infer(request: request)
                        XCTFail("Expected invalid response")
                    } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .invalidResponse) }
                    XCTAssertEqual(events.values.count, enabled ? 3 : 0)
                    if enabled { XCTAssertEqual(events.values[1].response?.shape, .invalidJSON) }
                    let sends = await transport.sends
                    XCTAssertEqual(sends, 1)
                }
            }
        }
    }

    func testNetworkTimeoutAndOfflineDoNotInventHTTPResponse() async throws {
        for provider in Provider.allCases {
            for code in [URLError.timedOut, .notConnectedToInternet, .networkConnectionLost] {
                let expected = BoneInferenceTransportError.network(.init(error: URLError(code)))
                let transport = MatrixTransport(failure: expected)
                let events = MatrixRecorder()
                do {
                    _ = try await provider.engine(transport, sink: events.sink).infer(request: request)
                    XCTFail("Expected network failure")
                } catch { XCTAssertEqual(error as? BoneInferenceTransportError, expected) }
                XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .transportFailed])
                XCTAssertTrue(events.values.allSatisfy { $0.response == nil })
            }
        }
    }

    func testCancellationDuringInFlightRequestStopsWithoutRetry() async throws {
        let transport = MatrixTransport(waitForCancellation: true)
        let events = MatrixRecorder()
        let engine = Provider.openAI.engine(transport, sink: events.sink)
        let req = request
        let task = Task { try await engine.infer(request: req) }
        await transport.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .transportFailed])
    }

    private func assertSafe(_ events: [BoneInferenceDiagnosticEvent]) {
        let rendered = String(reflecting: events)
        for value in ["credential-canary", "request-canary", "response-canary", "header-canary"] {
            XCTAssertFalse(rendered.contains(value))
        }
        XCTAssertEqual(Set(events.map(\.invocationID)).count, 1)
    }
}

private actor MatrixTransport: BoneInferenceHTTPTransport {
    let status: Int
    let body: String
    let failure: BoneInferenceTransportError?
    let waitForCancellation: Bool
    private(set) var sends = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(status: Int = 200, body: String = "", failure: BoneInferenceTransportError? = nil, waitForCancellation: Bool = false) {
        self.status = status; self.body = body; self.failure = failure; self.waitForCancellation = waitForCancellation
    }
    func waitUntilStarted() async {
        if sends > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume() }
        if waitForCancellation { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if let failure { throw failure }
        return .init(statusCode: status, data: Data(body.utf8), headers: ["x-request-id": "header-canary"])
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}

private final class MatrixRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BoneInferenceDiagnosticEvent] = []
    var values: [BoneInferenceDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var sink: BoneInferenceDiagnosticSink { .init { [self] event in lock.lock(); defer { lock.unlock() }; events.append(event) } }
}
