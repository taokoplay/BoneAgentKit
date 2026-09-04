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
        XCTAssertFalse(identity.matches(try Self.identity(addGenerationPrompt: false)))
        XCTAssertFalse(identity.matches(try Self.identity(maximumOutputTokens: 128)))
        XCTAssertFalse(identity.matches(try Self.identity(constraintCompilerVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(grammarRuntimeVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(stopMatcherVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(terminationContractVersion: 2)))
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
            toolEnvelopeID: nil,
            toolEnvelopeVersion: nil,
            constraintDecoderID: "llama-grammar",
            constraintDecoderVersion: "1",
            contextTokens: 4096,
            batchTokens: 256,
            constraintCompilerID: "bone.gbnf",
            constraintCompilerVersion: "1",
            constraintDialect: "bone-gbnf-v1",
            schemaCanonicalFormatVersion: 1,
            controlCanonicalFormatVersion: 1,
            compiledConstraintDigest: String(repeating: "e", count: 64),
            grammarRuntimeID: nil,
            grammarRuntimeVersion: nil,
            stopMatcherID: "bone.utf8-stop",
            stopMatcherVersion: "1",
            terminationContractVersion: 1
        ))
    }

    private static func identity(
        artifactSHA256: String = String(repeating: "a", count: 64),
        templateDigest: String = String(repeating: "b", count: 64),
        batchTokens: Int = 256,
        toolEnvelopeVersion: String? = "2",
        addGenerationPrompt: Bool? = true,
        maximumOutputTokens: Int? = 256,
        constraintCompilerVersion: String? = "1",
        grammarRuntimeVersion: String? = "1",
        stopMatcherVersion: String? = "1",
        terminationContractVersion: Int? = 1
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
            batchTokens: batchTokens,
            addGenerationPrompt: addGenerationPrompt,
            maximumOutputTokens: maximumOutputTokens,
            constraintCompilerID: "bone.gbnf",
            constraintCompilerVersion: constraintCompilerVersion,
            constraintDialect: "bone-gbnf-v1",
            schemaCanonicalFormatVersion: 1,
            controlCanonicalFormatVersion: 1,
            compiledConstraintDigest: String(repeating: "e", count: 64),
            grammarRuntimeID: "llama-grammar",
            grammarRuntimeVersion: grammarRuntimeVersion,
            stopMatcherID: "bone.utf8-stop",
            stopMatcherVersion: stopMatcherVersion,
            terminationContractVersion: terminationContractVersion
        )
    }
}
