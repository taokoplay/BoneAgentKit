import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class CloudConstraintFailClosedTests: XCTestCase {
    func testEndpointIdentityDriftRevokesOpenAICapabilityBeforeTransport() async throws {
        let verifiedConfiguration = configuration(baseURL: "https://verified.invalid")
        let currentConfiguration = configuration(baseURL: "https://changed.invalid")
        let adapter = BoneOpenAIOutputConstraintAdapter()
        let identity = try BoneProviderVerificationIdentitySupport.identity(
            configuration: verifiedConfiguration,
            protocolVariant: .openAI,
            apiVersion: "v1",
            modelID: "model",
            requestMapperID: "bone.openai.chat-completions",
            requestMapperVersion: "1",
            responseDecoderID: "bone.openai.chat-completions",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: .nonStreaming
        )
        let profile = try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .providerSmoke,
            verifiedAt: "2026-09-03",
            providerVerificationIdentities: [identity]
        )
        let transport = CloudConstraintCapturingTransport()
        let engine = BoneOpenAIInferenceEngine(
            configuration: currentConfiguration,
            transport: transport,
            modelCapabilityProfiles: ["model": profile]
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "private-prompt")],
            outputConstraint: .enumChoice(["private-a", "private-b"])
        )

        do {
            _ = try await engine.infer(request: request)
            XCTFail("identity drift must fail before transport")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedCapability(.constrainedOutput))
            XCTAssertFalse(String(describing: error).contains("private"))
        }
        let count = await transport.sendCount()
        XCTAssertEqual(count, 0)
    }

    func testOfficialEvidenceAloneCannotGrantProviderConstraint() throws {
        let profile = try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .official,
            verifiedAt: "2026-09-03"
        )
        let configuration = configuration(baseURL: "https://verified.invalid")
        let engine = BoneOpenAIInferenceEngine(
            configuration: configuration,
            transport: CloudConstraintCapturingTransport(),
            modelCapabilityProfiles: ["model": profile]
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "answer")],
            outputConstraint: .enumChoice(["a", "b"])
        )

        let resolved = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
        XCTAssertFalse(resolved.capabilities.contains(.constrainedOutput))
    }

    private func configuration(baseURL: String) -> BoneInferenceProviderConfiguration {
        .init(
            kind: .openAI,
            apiKey: "private-api-key",
            baseURL: URL(string: baseURL)!,
            endpointSecurityPolicy: .custom
        )
    }
}

private actor CloudConstraintCapturingTransport: BoneInferenceHTTPTransport {
    private var sends = 0

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        sends += 1
        return .init(statusCode: 200, data: Data(), headers: [:])
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        sends += 1
        return .init(statusCode: 200, events: [], headers: [:])
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendCount() -> Int { sends }
}
