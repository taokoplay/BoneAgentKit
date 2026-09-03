import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class GeminiOutputConstraintTests: XCTestCase {
    private let modelID = "gemini-2.5-flash"
    private let constraint = BoneInferenceOutputConstraint.enumChoice(["approve", "reject"])

    func testRequiresMatchingVerifiedIdentityBeforeTransport() async throws {
        let transport = GeminiConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .google)
        let engine = BoneGeminiInferenceEngine(configuration: configuration, transport: transport)

        await assertUnsupported(engine, transport: transport)
    }

    func testOfficialVerifiedModelMapsAndValidatesConstraint() async throws {
        let transport = GeminiConstraintTransport(response: Self.response(text: #"{"value":"approve"}"#))
        let configuration = Self.configuration(kind: .google)
        let engine = BoneGeminiInferenceEngine(
            configuration: configuration,
            transport: transport,
            modelCapabilityProfiles: [modelID: try profile(configuration: configuration)]
        )

        let response = try await engine.infer(request: request())
        XCTAssertEqual(response, .finish(.init(text: "approve")))
        let captured = await transport.body()
        let body = try XCTUnwrap(captured)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseSchema"])
        XCTAssertNil(json["tools"])
    }

    func testRejectsInvalidTruncatedAndMultipleCandidates() async throws {
        let configuration = Self.configuration(kind: .google)
        let responses = [
            Self.response(text: #"{"value":"Approve"}"#),
            Self.response(text: #"{"value":"approve"}"#, finishReason: "MAX_TOKENS"),
            Self.response(text: #"{"value":"approve"}"#, candidateCount: 2),
        ]
        for response in responses {
            let transport = GeminiConstraintTransport(response: response)
            let engine = BoneGeminiInferenceEngine(
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
        _ engine: BoneGeminiInferenceEngine,
        transport: GeminiConstraintTransport
    ) async {
        do {
            _ = try await engine.infer(request: request())
            XCTFail("unverified constraints must fail")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.constrainedOutput))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let count = await transport.sendCount()
        XCTAssertEqual(count, 0)
    }

    private func request() -> BoneInferenceRequest {
        .init(modelID: modelID, messages: [.init(role: .user, content: "decide")], outputConstraint: constraint)
    }

    private func profile(configuration: BoneInferenceProviderConfiguration) throws -> BoneModelCapabilityProfile {
        let adapter = BoneGeminiOutputConstraintAdapter()
        let identity = try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .geminiGenerateContent,
            apiVersion: "v1beta",
            modelID: modelID,
            requestMapperID: "bone.gemini.generate-content",
            requestMapperVersion: "1",
            responseDecoderID: "bone.gemini.generate-content",
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
            authenticationMode: .googleAPIKey,
            endpointSecurityPolicy: .custom
        )
    }

    private static func response(
        text: String,
        finishReason: String = "STOP",
        candidateCount: Int = 1
    ) -> Data {
        let candidate: [String: Any] = [
            "content": ["parts": [["text": text]]],
            "finishReason": finishReason,
        ]
        return try! JSONSerialization.data(withJSONObject: [
            "candidates": Array(repeating: candidate, count: candidateCount),
        ])
    }
}

private actor GeminiConstraintTransport: BoneInferenceHTTPTransport {
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
