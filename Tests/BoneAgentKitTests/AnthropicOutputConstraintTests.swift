import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class AnthropicOutputConstraintTests: XCTestCase {
    private let modelID = "claude-sonnet-4-5-20250929"
    private let constraint = BoneInferenceOutputConstraint.enumChoice(["approve", "reject"])

    func testRequiresOfficialKindAndMatchingIdentity() async throws {
        let officialConfiguration = Self.configuration(kind: .anthropic)
        let transport = AnthropicConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        await assertUnsupported(
            BoneAnthropicInferenceEngine(configuration: officialConfiguration, transport: transport),
            transport: transport
        )

        let compatibleConfiguration = Self.configuration(kind: .custom)
        let compatible = BoneAnthropicInferenceEngine(
            configuration: compatibleConfiguration,
            transport: transport,
            modelCapabilityProfiles: [modelID: try profile(configuration: compatibleConfiguration)]
        )
        await assertUnsupported(compatible, transport: transport)
    }

    func testOfficialVerifiedModelMapsAndValidatesConstraint() async throws {
        let transport = AnthropicConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .anthropic)
        let engine = BoneAnthropicInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [modelID: try profile(configuration: configuration)]
        )

        let response = try await engine.infer(request: request())
        XCTAssertEqual(response, .finish(.init(text: "approve")))
        let captured = await transport.body()
        let body = try XCTUnwrap(captured)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let outputConfig = try XCTUnwrap(json["output_config"] as? [String: Any])
        let format = try XCTUnwrap(outputConfig["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertNil(json["tools"])
    }

    func testRejectsEnumCaseDriftAndTruncation() async throws {
        let configuration = Self.configuration(kind: .anthropic)
        let responses = [
            Self.response(text: #"{"value":"Approve"}"#),
            Self.response(text: #"{"value":"approve"}"#, stopReason: "max_tokens"),
            Self.response(text: #"{"value":"approve"}"#, stopReason: "tool_use"),
        ]
        for response in responses {
            let transport = AnthropicConstraintTransport(response: response)
            let engine = BoneAnthropicInferenceEngine(
                configuration: configuration,
                transport: transport,
                modelCapabilityProfiles: [modelID: try profile(configuration: configuration)]
            )
            do {
                _ = try await engine.infer(request: request())
                XCTFail("invalid constrained output must fail")
            } catch let error as BoneInferenceTransportError {
                XCTAssertTrue([.invalidResponse, .outputTruncated].contains(error))
            }
        }
    }

    private func assertUnsupported(
        _ engine: BoneAnthropicInferenceEngine,
        transport: AnthropicConstraintTransport
    ) async {
        let before = await transport.sendCount()
        do {
            _ = try await engine.infer(request: request())
            XCTFail("unverified constraints must fail")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.constrainedOutput))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let after = await transport.sendCount()
        XCTAssertEqual(after, before)
    }

    private func request() -> BoneInferenceRequest {
        .init(modelID: modelID, messages: [.init(role: .user, content: "decide")], outputConstraint: constraint)
    }

    private func profile(configuration: BoneInferenceProviderConfiguration) throws -> BoneModelCapabilityProfile {
        let adapter = BoneAnthropicOutputConstraintAdapter()
        let identity = try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .anthropicMessages,
            apiVersion: "2023-06-01",
            modelID: modelID,
            requestMapperID: "bone.anthropic.messages",
            requestMapperVersion: "1",
            responseDecoderID: "bone.anthropic.messages",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: .nonStreaming
        )
        return try .init(
            capabilities: [.text, .constrainedOutput, .streaming],
            source: .providerSmoke,
            verifiedAt: "2026-09-03",
            providerVerificationIdentities: [identity]
        )
    }

    private static func configuration(kind: BoneInferenceProviderKind) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "test-key",
            baseURL: URL(string: "https://synthetic.invalid")!,
            authenticationMode: .anthropicDual,
            endpointSecurityPolicy: .custom
        )
    }

    private static func response(text: String, stopReason: String = "end_turn") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": text]],
            "stop_reason": stopReason,
        ])
    }
}

private actor AnthropicConstraintTransport: BoneInferenceHTTPTransport {
    private let response: Data
    private var requests: [URLRequest] = []
    init(response: Data) { self.response = response }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        requests.append(request)
        return .init(statusCode: 200, data: response, headers: [:])
    }
    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        requests.append(request)
        return .init(statusCode: 200, events: [], headers: [:])
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }
    func sendCount() -> Int { requests.count }
    func body() -> Data? { requests.last?.httpBody }
}
