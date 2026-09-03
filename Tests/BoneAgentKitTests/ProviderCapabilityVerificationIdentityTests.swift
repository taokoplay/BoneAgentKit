import XCTest
@testable import BoneAgentKit

final class ProviderCapabilityVerificationIdentityTests: XCTestCase {
    func testIdentityMatchesOnlyExactProviderExecutionConfiguration() throws {
        let identity = try Self.identity()

        XCTAssertTrue(identity.matches(identity))
        XCTAssertFalse(identity.matches(try Self.identity(modelID: "gpt-4.1")))
        XCTAssertFalse(identity.matches(try Self.identity(endpointIdentityDigest: String(repeating: "b", count: 64))))
        XCTAssertFalse(identity.matches(try Self.identity(requestMapperVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(invocation: .streaming)))
    }

    func testIdentityRejectsInvalidOrSensitiveShape() {
        XCTAssertThrowsError(try Self.identity(endpointIdentityDigest: "https://api.openai.com/v1"))
        XCTAssertThrowsError(try Self.identity(modelID: ""))
        XCTAssertThrowsError(try Self.identity(requestMapperVersion: String(repeating: "x", count: 129)))
        XCTAssertThrowsError(try Self.identity(apiVersion: "version with spaces"))
    }

    func testProviderSmokeRequiresProviderIdentityForConstrainedOutput() throws {
        XCTAssertThrowsError(try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .providerSmoke,
            verifiedAt: "2026-09-03"
        )) { error in
            XCTAssertEqual(
                error as? BoneModelCapabilityProfile.ValidationError,
                .missingProviderVerificationIdentity
            )
        }

        XCTAssertNoThrow(try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .providerSmoke,
            verifiedAt: "2026-09-03",
            providerVerificationIdentities: [try Self.identity()]
        ))
    }

    private static func identity(
        endpointIdentityDigest: String = String(repeating: "a", count: 64),
        modelID: String = "gpt-4.1-mini",
        apiVersion: String = "v1",
        requestMapperVersion: String = "1",
        invocation: BoneInferenceInvocationIdentity = .nonStreaming
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        try .init(
            providerKind: .openAI,
            protocolVariant: .openAI,
            endpointIdentityDigest: endpointIdentityDigest,
            apiVersion: apiVersion,
            modelID: modelID,
            requestMapperID: "bone.openai.chat-completions",
            requestMapperVersion: requestMapperVersion,
            responseDecoderID: "bone.openai.chat-completions",
            responseDecoderVersion: "1",
            constraintDialectID: "openai.json-schema",
            constraintDialectVersion: "1",
            invocation: invocation
        )
    }
}
