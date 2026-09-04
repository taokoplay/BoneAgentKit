import XCTest
@testable import BoneAgentKit

final class ArchitectureNamingTests: XCTestCase {
    func testInvocationModeIsSharedByResolvedCapabilitiesAndProviderIdentity() throws {
        let resolved = BoneResolvedInferenceCapabilities(
            modelID: "model",
            invocation: .streaming,
            capabilities: [.text, .streaming]
        )
        XCTAssertEqual(resolved.invocation, BoneInferenceInvocationMode.streaming)

        let identity = try BoneProviderCapabilityVerificationIdentity(
            providerKind: .openAI,
            protocolVariant: .openAI,
            endpointIdentityDigest: String(repeating: "a", count: 64),
            apiVersion: "v1",
            modelID: "model",
            requestMapperID: "mapper",
            requestMapperVersion: "1",
            responseDecoderID: "decoder",
            responseDecoderVersion: "1",
            constraintDialectID: "dialect",
            constraintDialectVersion: "1",
            invocation: .streaming
        )
        XCTAssertEqual(identity.invocation, resolved.invocation)
    }

    func testWorkflowPersistenceUsesWorkflowDomainName() async throws {
        let persistence: any BoneWorkflowPersistence = BoneInMemoryWorkflowPersistence()
        _ = persistence
    }

    func testBufferedStreamingIsDistinctFromEventStreaming() {
        func acceptsBuffered(_ value: any BoneInferenceBufferedStreaming) { _ = value }
        func acceptsEvents(_ value: any BoneInferenceEventStreaming) { _ = value }
        _ = acceptsBuffered
        _ = acceptsEvents
    }
}
