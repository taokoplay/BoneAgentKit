import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ServerReasoningTests: XCTestCase {
    private let request = BoneInferenceRequest(modelID: "verified-model", messages: [.init(role: .user, content: "hi")])
    private func configuration(_ kind: BoneInferenceProviderKind = .agnes) -> BoneInferenceProviderConfiguration {
        .init(kind: kind, apiKey: "fixture", baseURL: URL(string: "https://example.com/v1")!)
    }

    func testDefaultDoesNotSendThinkingField() async throws {
        let transport = ThinkingTransport()
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport)
        _ = try await engine.infer(request: request)
        let data = await transport.body
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        XCTAssertNil(body["chat_template_kwargs"])
    }

    func testEnabledIsIndependentOfHiddenDisclosure() async throws {
        let transport = ThinkingTransport()
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(), transport: transport, serverReasoning: .enabled, verifiedThinkingModelIDs: [request.modelID])
        let supported = try engine.supportedServerReasoning(for: request, invocation: .streaming)
        XCTAssertTrue(supported.contains(.enabled))
        XCTAssertFalse(supported.contains(.disabled))
        let result = try await engine.inferDetailed(request: request)
        let data = await transport.body
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
        XCTAssertEqual((body["chat_template_kwargs"] as? [String: Bool])?["enable_thinking"], true)
        XCTAssertFalse(String(reflecting: result).contains("private-canary"))
    }

    func testUnsupportedConfigurationsFailBeforeSending() async throws {
        for (kind, mode, models): (BoneInferenceProviderKind, BoneInferenceServerReasoning, Set<String>) in [
            (.agnes, .disabled, [request.modelID]),
            (.agnes, .enabled, []),
            (.custom, .enabled, [request.modelID])
        ] {
            let transport = ThinkingTransport()
            let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind), transport: transport, serverReasoning: mode, verifiedThinkingModelIDs: models)
            do {
                _ = try await engine.infer(request: request)
                XCTFail("Expected unsupported option")
            } catch { XCTAssertEqual(error as? BoneInferenceUnsupportedServerReasoning, .init(requested: mode)) }
            let sends = await transport.sends
            XCTAssertEqual(sends, 0)
        }
    }
}

private actor ThinkingTransport: BoneInferenceHTTPTransport {
    var body: Data?
    var sends = 0
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1; body = request.httpBody
        return .init(statusCode: 200, data: Data(#"{"choices":[{"index":0,"message":{"role":"assistant","content":"ok","reasoning_content":"private-canary"},"finish_reason":"stop"}]}"#.utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}
