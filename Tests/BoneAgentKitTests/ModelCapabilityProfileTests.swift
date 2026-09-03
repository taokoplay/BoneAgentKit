import XCTest
@testable import BoneAgentKit

final class ModelCapabilityProfileTests: XCTestCase {
    func testLegacyProfileDecodesWithoutVerificationIdentity() throws {
        let data = Data(#"{"capabilities":["text"],"source":"runtimeSmoke","verifiedAt":"2026-09-03"}"#.utf8)

        let profile = try JSONDecoder().decode(BoneModelCapabilityProfile.self, from: data)

        XCTAssertNil(profile.verificationIdentity)
        XCTAssertTrue(profile.providerVerificationIdentities.isEmpty)
        XCTAssertEqual(profile.capabilities, [.text])
    }

    func testRuntimeSmokeRequiresIdentityForAdvancedCapabilities() {
        XCTAssertThrowsError(try BoneModelCapabilityProfile(
            capabilities: [.text, .toolCalling],
            source: .runtimeSmoke,
            verifiedAt: "2026-09-03"
        ))
        XCTAssertThrowsError(try BoneModelCapabilityProfile(
            capabilities: [.text, .constrainedOutput],
            source: .runtimeSmoke,
            verifiedAt: "2026-09-03"
        ))
        XCTAssertNoThrow(try BoneModelCapabilityProfile(
            capabilities: [.text],
            source: .runtimeSmoke,
            verifiedAt: "2026-09-03"
        ))
    }

    func testVerificationIdentityMatchesOnlyIdenticalExecutionConfiguration() throws {
        let identity = try Self.identity()
        XCTAssertTrue(identity.matches(identity))
        XCTAssertFalse(identity.matches(try Self.identity(templateDigest: String(repeating: "d", count: 64))))
        XCTAssertFalse(identity.matches(try Self.identity(batchTokens: 128)))
        XCTAssertFalse(identity.matches(try Self.identity(toolEnvelopeVersion: "3")))
    }

    func testIdentityValidatesDigestsAndPairedOptionalComponents() {
        XCTAssertThrowsError(try Self.identity(artifactSHA256: "not-a-digest"))
        XCTAssertThrowsError(try BoneCapabilityVerificationIdentity(
            artifactSHA256: String(repeating: "a", count: 64),
            runtimeID: "llama.cpp",
            runtimeVersion: 1,
            tokenizerID: "gguf",
            tokenizerVersion: "1",
            templateDigest: String(repeating: "b", count: 64),
            rendererID: "native",
            rendererVersion: "1",
            reasoningMode: "disabled",
            generationControlDigest: String(repeating: "c", count: 64),
            toolEnvelopeID: "envelope",
            toolEnvelopeVersion: nil,
            constraintDecoderID: nil,
            constraintDecoderVersion: nil,
            contextTokens: 4096,
            batchTokens: 256
        ))
    }

    private static func identity(
        artifactSHA256: String = String(repeating: "a", count: 64),
        templateDigest: String = String(repeating: "b", count: 64),
        batchTokens: Int = 256,
        toolEnvelopeVersion: String? = "2"
    ) throws -> BoneCapabilityVerificationIdentity {
        try .init(
            artifactSHA256: artifactSHA256,
            runtimeID: "llama.cpp",
            runtimeVersion: 1,
            tokenizerID: "gguf",
            tokenizerVersion: "1",
            templateDigest: templateDigest,
            rendererID: "native",
            rendererVersion: "1",
            reasoningMode: "disabled",
            generationControlDigest: String(repeating: "c", count: 64),
            toolEnvelopeID: "envelope",
            toolEnvelopeVersion: toolEnvelopeVersion,
            constraintDecoderID: "llama-grammar",
            constraintDecoderVersion: "1",
            contextTokens: 4096,
            batchTokens: batchTokens
        )
    }
}
