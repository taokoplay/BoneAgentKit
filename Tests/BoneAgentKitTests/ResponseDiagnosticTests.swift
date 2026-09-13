import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ResponseDiagnosticTests: XCTestCase {
    func testSummaryDistinguishesMissingInvalidAndZero() {
        let value = summary(#"{"choices":[{"finish_reason":"length","message":{"tool_calls":[]}}],"usage":{"prompt_tokens":0,"completion_tokens":true,"total_tokens":-1}}"#)
        XCTAssertEqual(value.inputTokens, .value(0))
        XCTAssertEqual(value.outputTokens, .invalid)
        XCTAssertEqual(value.totalTokens, .invalid)
        XCTAssertEqual(value.reasoningTokens, .unknown)
        XCTAssertEqual(value.stop, .length)
        XCTAssertEqual(value.toolCount, .value(0))
        XCTAssertEqual(summary(#"{"usage":"bad"}"#).inputTokens, .invalid)
        XCTAssertEqual(summary(#"{}"#).inputTokens, .unknown)
        XCTAssertEqual(summary(#"{"usage":{"prompt_tokens":1.5}}"#).inputTokens, .invalid)
    }

    func testSummaryIsBoundedAndDoesNotExposeCanaries() {
        let value = summary(#"{"choices":[{"finish_reason":"secret-stop","message":{"content":"secret-body","tool_calls":[{"arguments":"secret-tool"}]}}],"id":"secret-id"}"#)
        XCTAssertEqual(value.stop, .other)
        XCTAssertFalse(String(reflecting: value).contains("secret"))
        XCTAssertEqual(summary("not JSON").shape, .invalidJSON)
        XCTAssertEqual(summary(String(repeating: "x", count: 1_048_577)).shape, .tooLarge)
    }

    func testProviderSummaries() {
        let anthropic = BoneInferenceResponseDiagnostic.capture(.init(statusCode: 200, data: Data(#"{"stop_reason":"max_tokens","content":[{"type":"tool_use"}],"usage":{"input_tokens":2,"output_tokens":3}}"#.utf8)), wire: .anthropic)
        XCTAssertEqual(anthropic.stop, .length)
        XCTAssertEqual(anthropic.totalTokens, .unknown)
        XCTAssertEqual(anthropic.toolCount, .value(1))
        let gemini = BoneInferenceResponseDiagnostic.capture(.init(statusCode: 200, data: Data(#"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"functionCall":{}}]}}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":3,"thoughtsTokenCount":4}}"#.utf8)), wire: .gemini)
        XCTAssertEqual(gemini.toolCount, .value(1))
        XCTAssertEqual(gemini.reasoningTokens, .value(4))
    }

    func testTruncationEmitsResponseBeforeOriginalError() async throws {
        let recorder = DiagnosticRecorder()
        let transport = DiagnosticTransport(data: Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"partial"},"finish_reason":"length"}],"usage":{"prompt_tokens":100,"completion_tokens":4096}}"#.utf8))
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!), transport: transport, diagnostics: .init { recorder.record($0) })
        do {
            _ = try await engine.infer(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "hi")]))
            XCTFail("Expected truncated response")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .outputTruncated) }
        let events = recorder.events
        XCTAssertEqual(events.map(\.phase), [.transportAttempt, .httpResponseReceived, .responseValidationFailed])
        XCTAssertEqual(Set(events.map(\.invocationID)).count, 1)
        XCTAssertEqual(events[1].response?.outputTokens, .value(4096))
        let sends = await transport.sends
        XCTAssertEqual(sends, 1)
    }

    func testTransportErrorDoesNotFabricateResponse() async throws {
        let recorder = DiagnosticRecorder()
        let transport = DiagnosticTransport(data: Data(), failure: .idleTimedOut)
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!), transport: transport, diagnostics: .init { recorder.record($0) })
        do {
            _ = try await engine.infer(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "hi")]))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .idleTimedOut) }
        XCTAssertEqual(recorder.events.map(\.phase), [.transportAttempt, .transportFailed])
        XCTAssertTrue(recorder.events.allSatisfy { $0.response == nil })
    }

    func testEnabledAndDisabledDiagnosticsReturnSameResult() async throws {
        let recorder = DiagnosticRecorder()
        let data = Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}"#.utf8)
        let config = BoneInferenceProviderConfiguration(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!)
        let request = BoneInferenceRequest(modelID: "fixture", messages: [.init(role: .user, content: "hi")])
        let plain = try await BoneOpenAIInferenceEngine(configuration: config, transport: DiagnosticTransport(data: data)).infer(request: request)
        let observed = try await BoneOpenAIInferenceEngine(configuration: config, transport: DiagnosticTransport(data: data), diagnostics: .init { recorder.record($0) }).infer(request: request)
        XCTAssertEqual(plain, observed)
        XCTAssertEqual(recorder.events.map(\.phase), [.transportAttempt, .httpResponseReceived, .resultValidated])
    }

    func testDisabledDebugDoesNotBuildContext() {
        var builds = 0
        func context() -> BoneAgentLogContext { builds += 1; return .init() }
        BoneAgentLoggerConfiguration().write(.debug, "hidden", context: context())
        XCTAssertEqual(builds, 0)
        XCTAssertFalse(BoneAgentLoggerConfiguration(isDebugEnabled: true).includesSensitivePayloads)
    }

    private func summary(_ text: String) -> BoneInferenceResponseDiagnostic {
        .capture(.init(statusCode: 200, data: Data(text.utf8)), wire: .openAI)
    }
}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [BoneInferenceDiagnosticEvent] = []
    var events: [BoneInferenceDiagnosticEvent] { lock.lock(); defer { lock.unlock() }; return values }
    func record(_ event: BoneInferenceDiagnosticEvent) { lock.lock(); defer { lock.unlock() }; values.append(event) }
}

private actor DiagnosticTransport: BoneInferenceHTTPTransport {
    let data: Data
    let failure: BoneInferenceTransportError?
    private(set) var sends = 0
    init(data: Data, failure: BoneInferenceTransportError? = nil) { self.data = data; self.failure = failure }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1
        if let failure { throw failure }
        return .init(statusCode: 200, data: data)
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}
