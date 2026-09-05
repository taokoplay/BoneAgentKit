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

    func testCurrentVerificationIdentityRoundTripsWithExplicitSchemaVersion() throws {
        let identity = try Self.identity()
        let data = try JSONEncoder().encode(identity)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["schemaVersion"] as? Int, BoneLocalExecutionVerificationIdentity.currentSchemaVersion)
        XCTAssertEqual(object["probeProtocolVersion"] as? Int, 2)
        XCTAssertEqual(try JSONDecoder().decode(BoneLocalExecutionVerificationIdentity.self, from: data), identity)
    }

    func testRejectsMissingOrUnsupportedIdentitySchemaVersion() throws {
        let encoded = try JSONEncoder().encode(Self.identity())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "schemaVersion")
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneLocalExecutionVerificationIdentity.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))

        for unsupportedVersion in [1, 2] {
            object["schemaVersion"] = unsupportedVersion
            XCTAssertThrowsError(try JSONDecoder().decode(
                BoneLocalExecutionVerificationIdentity.self,
                from: try JSONSerialization.data(withJSONObject: object)
            ))
        }
    }

    func testRejectsMissingOrInvalidProbeProtocolVersion() throws {
        let encoded = try JSONEncoder().encode(Self.identity())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        object.removeValue(forKey: "probeProtocolVersion")
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneLocalExecutionVerificationIdentity.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))

        object["probeProtocolVersion"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneLocalExecutionVerificationIdentity.self,
            from: try JSONSerialization.data(withJSONObject: object)
        ))
    }

    func testRejectsAlpha8ToolOnlyAndConstrainedIdentityFields() throws {
        let encoded = try JSONEncoder().encode(Self.identity())
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        var toolOnly = current
        toolOnly.removeValue(forKey: "schemaVersion")
        for key in [
            "grammarParserID", "grammarParserVersion", "constraintCompilerID",
            "constraintCompilerVersion", "constraintDialect", "schemaCanonicalFormatVersion",
            "controlCanonicalFormatVersion", "compiledConstraintDigest", "grammarSamplerID",
            "grammarSamplerVersion", "stopMatcherID", "stopMatcherVersion",
            "terminationContractVersion"
        ] {
            toolOnly.removeValue(forKey: key)
        }
        toolOnly["constraintDecoderID"] = "llama.cpp.gbnf-decoder"
        toolOnly["constraintDecoderVersion"] = "binary-v1"
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneLocalExecutionVerificationIdentity.self,
            from: try JSONSerialization.data(withJSONObject: toolOnly)
        ))

        var constrained = current
        constrained.removeValue(forKey: "schemaVersion")
        constrained.removeValue(forKey: "grammarParserID")
        constrained.removeValue(forKey: "grammarParserVersion")
        constrained.removeValue(forKey: "grammarSamplerID")
        constrained.removeValue(forKey: "grammarSamplerVersion")
        constrained["constraintDecoderID"] = "llama.cpp.gbnf-decoder"
        constrained["constraintDecoderVersion"] = "binary-v1"
        constrained["grammarRuntimeID"] = "llama.cpp.gbnf-sampler"
        constrained["grammarRuntimeVersion"] = "binary-v1"
        XCTAssertThrowsError(try JSONDecoder().decode(
            BoneLocalExecutionVerificationIdentity.self,
            from: try JSONSerialization.data(withJSONObject: constrained)
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
        XCTAssertFalse(identity.matches(try Self.identity(grammarParserVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(grammarSamplerVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(stopMatcherVersion: "2")))
        XCTAssertFalse(identity.matches(try Self.identity(terminationContractVersion: 2)))
        XCTAssertFalse(identity.matches(try Self.identity(probeProtocolVersion: 3)))
    }

    func testIdentityValidatesDigestsAndPairedOptionalComponents() {
        XCTAssertThrowsError(try Self.identity(artifactSHA256: "not-a-digest"))
        XCTAssertThrowsError(try BoneLocalExecutionVerificationIdentity(
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
            grammarParserID: nil,
            grammarParserVersion: nil,
            contextTokens: 4096,
            batchTokens: 256,
            probeProtocolVersion: 2
        ))
        XCTAssertThrowsError(try BoneLocalExecutionVerificationIdentity(
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
            grammarParserID: "llama-grammar",
            grammarParserVersion: "1",
            contextTokens: 4096,
            batchTokens: 256,
            constraintCompilerID: "bone.gbnf",
            constraintCompilerVersion: "1",
            constraintDialect: "bone-gbnf-v1",
            schemaCanonicalFormatVersion: 1,
            controlCanonicalFormatVersion: 1,
            compiledConstraintDigest: String(repeating: "e", count: 64),
            grammarSamplerID: nil,
            grammarSamplerVersion: nil,
            stopMatcherID: "bone.utf8-stop",
            stopMatcherVersion: "1",
            terminationContractVersion: 1,
            probeProtocolVersion: 2
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
        grammarParserVersion: String? = "1",
        grammarSamplerVersion: String? = "1",
        stopMatcherVersion: String? = "1",
        terminationContractVersion: Int? = 1,
        probeProtocolVersion: Int = 2
    ) throws -> BoneLocalExecutionVerificationIdentity {
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
            grammarParserID: "llama-grammar-parser",
            grammarParserVersion: grammarParserVersion,
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
            grammarSamplerID: "llama-grammar-sampler",
            grammarSamplerVersion: grammarSamplerVersion,
            stopMatcherID: "bone.utf8-stop",
            stopMatcherVersion: stopMatcherVersion,
            terminationContractVersion: terminationContractVersion,
            probeProtocolVersion: probeProtocolVersion
        )
    }
}
