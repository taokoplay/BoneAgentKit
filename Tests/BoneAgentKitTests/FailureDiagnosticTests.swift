import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class FailureDiagnosticTests: XCTestCase {
    func testSummaryClassifiesOnlyExplicitEvidenceWithoutLeakingStrings() {
        let forbidden = capture(403, #"{"error":{"message":"secret-message","code":"unknown-secret-code"}}"#)
        XCTAssertEqual(forbidden.bodyKind, .json)
        XCTAssertEqual(forbidden.errorCategory, .unknown)
        XCTAssertFalse(String(reflecting: forbidden).contains("secret"))
        XCTAssertEqual(capture(403, #"{"error":{"code":"content_policy_violation"}}"#).errorCategory, .safety)
        XCTAssertEqual(capture(403, #"{"error":{"type":"insufficient_quota"}}"#).errorCategory, .quota)
        XCTAssertEqual(capture(403, "<html>blocked</html>", ["CONTENT-TYPE": "text/html; charset=utf-8"]).bodyKind, .html)
        XCTAssertEqual(capture(403, "denied", ["Content-Type": "text/plain"]).bodyKind, .text)
        XCTAssertEqual(capture(403, "").bodyKind, .empty)
        XCTAssertEqual(capture(401, "").errorCategory, .authentication)
        XCTAssertEqual(capture(429, "").errorCategory, .rateLimit)
        XCTAssertEqual(capture(200, #"{"error":{"code":"insufficient_quota"}}"#).errorCategory, .none)
    }

    func testHTTPJSONAndResultFailuresHaveDifferentStagesAndUnchangedErrors() async throws {
        for (status, body, stage, expectedError) in [
            (403, "<html>denied</html>", BoneInferenceDiagnosticEvent.FailureStage.httpStatus, BoneInferenceTransportError.httpStatus(403)),
            (200, "bad json", .jsonDecoding, .invalidResponse),
            (200, "{}", .resultValidation, .invalidResponse)
        ] {
            let events = FailureEventRecorder()
            let transport = BoneInferenceURLSessionTransport(loader: { _ in
                (Data(body.utf8), .init(statusCode: status))
            })
            let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!), transport: transport, diagnostics: .init { events.append($0) })
            do {
                _ = try await engine.infer(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "secret-prompt")]))
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, expectedError) }
            XCTAssertEqual(events.values.last?.failureStage, stage)
            XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .httpResponseReceived, .responseValidationFailed])
        }
    }

    func testFailureCaptureIsExplicitBoundedAndFiltersHeaders() async throws {
        let records = FailureCaptureRecorder()
        let capture = BoneInferenceFailureCapture(maximumBodyBytes: 8) { records.append($0) }
        let transport = BoneInferenceURLSessionTransport(loader: { _ in
            (Data("secret-error-body".utf8), .init(statusCode: 403, headers: [
                "Content-Type": "text/plain", "X-Request-ID": "request-123", "CF-Ray": "ray-123",
                "Set-Cookie": "secret-cookie", "Authorization": "secret-auth", "X-Other": "secret-header"
            ]))
        }, failureCapture: capture)
        var request = URLRequest(url: URL(string: "https://example.com/private?token=secret-url")!)
        request.setValue("secret-key", forHTTPHeaderField: "Authorization")
        let response = try await transport.send(request)
        XCTAssertEqual(response.statusCode, 403)
        XCTAssertEqual(response.data, Data("secret-error-body".utf8))
        let record = try XCTUnwrap(records.values.first)
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(record.body, Data("secret-e".utf8))
        XCTAssertEqual(record.completion, .byteLimit)
        XCTAssertEqual(record.headers, ["content-type": "text/plain", "x-request-id": "request-123", "cf-ray": "ray-123"])
        XCTAssertFalse(String(reflecting: record).contains("secret"))
        XCTAssertFalse(String(reflecting: record).contains("request-123"))
    }

    func testSuccessIsNeverCapturedAndHeaderValuesAreBounded() async throws {
        let records = FailureCaptureRecorder()
        let capture = BoneInferenceFailureCapture { records.append($0) }
        let request = URLRequest(url: URL(string: "https://example.com")!)
        _ = try await BoneInferenceURLSessionTransport(loader: { _ in
            (Data("secret-success".utf8), .init(statusCode: 200))
        }, failureCapture: capture).send(request)
        XCTAssertTrue(records.values.isEmpty)
        _ = try await BoneInferenceURLSessionTransport(loader: { _ in
            (Data(), .init(statusCode: 403, headers: ["Request-ID": "bad\nvalue", "CF-Ray": String(repeating: "a", count: 513)]))
        }, failureCapture: capture).send(request)
        XCTAssertEqual(records.values.first?.body, Data())
        XCTAssertEqual(records.values.first?.completion, .complete)
        XCTAssertEqual(records.values.first?.headers, [:])
        XCTAssertEqual(BoneInferenceFailureCapture(maximumBodyBytes: Int.max) { _ in }.maximumBodyBytes, 65_536)
    }

    func testAnthropicAndGeminiReportHTTPFailureWithoutChangingErrors() async throws {
        for kind in [BoneInferenceProviderKind.anthropic, .google] {
            let events = FailureEventRecorder()
            let transport = BoneInferenceURLSessionTransport(loader: { _ in (Data("denied".utf8), .init(statusCode: 403)) })
            let configuration = BoneInferenceProviderConfiguration(kind: kind, apiKey: "fixture", baseURL: URL(string: "https://example.com")!, authenticationMode: kind == .google ? .googleAPIKey : .anthropicDual)
            let sink = BoneInferenceDiagnosticSink { events.append($0) }
            let engine: any BoneInferenceEngine = kind == .anthropic
                ? BoneAnthropicInferenceEngine(configuration: configuration, transport: transport, diagnostics: sink)
                : BoneGeminiInferenceEngine(configuration: configuration, transport: transport, diagnostics: sink)
            do {
                _ = try await engine.infer(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "hi")]))
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
            XCTAssertEqual(events.values.last?.failureStage, .httpStatus)
            XCTAssertEqual(events.values.count, 3)
        }
    }

    func testInvalidUsageDoesNotEmitValidatedBeforeFailure() async throws {
        let events = FailureEventRecorder()
        let transport = BoneInferenceURLSessionTransport(loader: { _ in
            (Data(#"{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":"bad"}"#.utf8), .init(statusCode: 200))
        })
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://example.com")!),
            transport: transport, diagnostics: .init { events.append($0) })
        do {
            _ = try await engine.infer(request: .init(modelID: "fixture", messages: [.init(role: .user, content: "hi")]))
            XCTFail("Expected invalid usage")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .invalidResponse) }
        XCTAssertEqual(events.values.map(\.phase), [.transportAttempt, .httpResponseReceived, .responseValidationFailed])
        XCTAssertEqual(events.values.last?.failureStage, .resultValidation)
    }

    func testCaptureRejectsDuplicateHeadersAndPreservesRawInvalidUTF8() async throws {
        let records = FailureCaptureRecorder()
        let capture = BoneInferenceFailureCapture(maximumBodyBytes: 2, maximumDuration: .infinity) { records.append($0) }
        XCTAssertEqual(capture.maximumDuration, 2)
        XCTAssertEqual(BoneInferenceFailureCapture(maximumDuration: 100).maximumDuration, 10)
        XCTAssertEqual(BoneInferenceFailureCapture(maximumBodyBytes: -1).maximumBodyBytes, 0)
        let transport = BoneInferenceURLSessionTransport(loader: { _ in
            (Data([0xFF, 0x00, 0xFE]), .init(statusCode: 403, headers: ["CF-Ray": "first", "cf-ray": "second", "X-Request-ID": "safe"]))
        }, failureCapture: capture)
        _ = try await transport.send(URLRequest(url: URL(string: "https://example.com")!))
        let result = try XCTUnwrap(records.values.first)
        XCTAssertEqual(result.body, Data([0xFF, 0x00]))
        XCTAssertEqual(result.completion, .byteLimit)
        XCTAssertEqual(result.headers, ["x-request-id": "safe"])
        var dumped = ""
        dump(result, to: &dumped)
        XCTAssertFalse(dumped.contains("safe"))
    }

    func testOptionalLoggerPrintsOnlySafeSummaryAndFailureStage() async throws {
        let logger = SafeDiagnosticLogger()
        let transport = BoneInferenceURLSessionTransport(loader: { _ in
            (Data(#"{"error":{"message":"secret-body","code":"unknown-secret"}}"#.utf8),
             .init(statusCode: 403, headers: ["CF-Ray": "secret-ray", "Set-Cookie": "secret-cookie"]))
        })
        let engine = BoneOpenAIInferenceEngine(configuration: .init(kind: .agnes, apiKey: "secret-key", baseURL: URL(string: "https://example.com/private")!),
            transport: transport, diagnostics: .logging(to: .init(logger: logger)))
        do {
            _ = try await engine.infer(request: .init(modelID: "secret-model", messages: [.init(role: .user, content: "secret-prompt")]))
            XCTFail("Expected HTTP rejection")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
        let lines = logger.lines.joined(separator: "\n")
        XCTAssertTrue(lines.contains("statusCode=403"))
        XCTAssertTrue(lines.contains("bodyKind=json"))
        XCTAssertTrue(lines.contains("failureStage=httpStatus"))
        XCTAssertFalse(lines.contains("secret"))
        XCTAssertFalse(lines.contains("example.com"))
        XCTAssertEqual(logger.lines.count, 2) // transportAttempt is debug and disabled by default
    }

    private func capture(_ status: Int, _ body: String, _ headers: [String: String] = [:]) -> BoneInferenceResponseDiagnostic {
        .capture(.init(statusCode: status, data: Data(body.utf8), headers: headers), wire: .openAI)
    }
}

final class FailureCaptureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BoneInferenceFailureResponse] = []
    var values: [BoneInferenceFailureResponse] { lock.withLock { storage } }
    func append(_ value: BoneInferenceFailureResponse) { lock.withLock { storage.append(value) } }
}

private final class FailureEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BoneInferenceDiagnosticEvent] = []
    var values: [BoneInferenceDiagnosticEvent] { lock.withLock { storage } }
    func append(_ value: BoneInferenceDiagnosticEvent) { lock.withLock { storage.append(value) } }
}

private final class SafeDiagnosticLogger: BoneAgentLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {
        let line = message() + " " + (context?.values.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") ?? "")
        lock.withLock { storage.append(line) }
    }
}
