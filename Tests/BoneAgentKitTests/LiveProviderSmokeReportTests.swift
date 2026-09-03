import Foundation
import XCTest
@testable import BoneAgentKit

final class LiveProviderSmokeReportTests: XCTestCase {
    func testReportContainsOnlyAllowlistedAggregateFields() throws {
        let identity = try Self.identity()
        let report = try BoneLiveConstraintSmokeReport(
            provider: .openAI,
            modelID: "gpt-4.1-mini",
            invocation: .nonStreaming,
            identity: identity,
            attemptedCount: 3,
            succeededCount: 2,
            failureCounts: [.invalidResponse: 1],
            durationMilliseconds: 10,
            verifiedAt: "2026-09-03"
        )
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)

        for forbidden in ["prompt", "schemaBody", "outputBody", "apiKey", "header", "https://"] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
        XCTAssertEqual(try JSONDecoder().decode(BoneLiveConstraintSmokeReport.self, from: data), report)
    }

    func testReportRejectsSensitiveOrURLShapedModelIDs() throws {
        for modelID in [
            "https://example.invalid/private",
            "model?apiKey=PRIVATE-CANARY-7f1d",
            "Authorization:Bearer-secret",
            "model name",
        ] {
            XCTAssertThrowsError(try BoneLiveConstraintSmokeReport(
                provider: .openAI,
                modelID: modelID,
                invocation: .nonStreaming,
                identity: Self.identity(modelID: modelID),
                attemptedCount: 1,
                succeededCount: 1,
                failureCounts: [:],
                durationMilliseconds: 1,
                verifiedAt: "2026-09-03"
            ))
        }
    }

    func testReportAcceptsRepresentativeProviderModelIDs() throws {
        for modelID in ["gpt-4.1-mini", "claude-sonnet-4-5", "models/gemini-2.5-flash"] {
            XCTAssertNoThrow(try BoneLiveConstraintSmokeReport(
                provider: .openAI,
                modelID: modelID,
                invocation: .nonStreaming,
                identity: Self.identity(modelID: modelID),
                attemptedCount: 1,
                succeededCount: 1,
                failureCounts: [:],
                durationMilliseconds: 1,
                verifiedAt: "2026-09-03"
            ))
        }
    }

    func testReportDecodeCannotBypassCountValidation() throws {
        let identityData = try JSONEncoder().encode(Self.identity())
        let identity = String(decoding: identityData, as: UTF8.self)
        let data = Data(#"{"schemaVersion":1,"provider":"OpenAI","modelID":"gpt-4.1-mini","invocation":"nonStreaming","identity":\#(identity),"attemptedCount":1,"succeededCount":1,"failureCounts":{"invalidResponse":1},"durationMilliseconds":1,"verifiedAt":"2026-09-03"}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(BoneLiveConstraintSmokeReport.self, from: data))
    }

    func testSyntheticRunnerAggregatesFailuresWithoutPayloads() async throws {
        let identity = try Self.identity()
        let report = try await BoneLiveConstraintSmoke.run(
            provider: .openAI,
            modelID: "gpt-4.1-mini",
            invocation: .nonStreaming,
            engine: SmokeScriptedEngine(
                responses: [
                    .success(.finish(.init(text: "pass"))),
                    .failure(BoneInferenceTransportError.outputTruncated),
                ]
            ),
            identity: identity,
            iterations: 2
        )

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.failureCounts, [.outputTruncated: 1])
    }

    private static func identity(
        modelID: String = "gpt-4.1-mini"
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        try .init(
            providerKind: .openAI,
            protocolVariant: .openAI,
            endpointIdentityDigest: String(repeating: "a", count: 64),
            apiVersion: "v1",
            modelID: modelID,
            requestMapperID: "bone.openai.chat-completions",
            requestMapperVersion: "1",
            responseDecoderID: "bone.openai.chat-completions",
            responseDecoderVersion: "1",
            constraintDialectID: "bone.openai.chat-completions.constraint",
            constraintDialectVersion: "1",
            invocation: .nonStreaming
        )
    }
}

private actor SmokeScriptedEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .constrainedOutput]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var responses: [Result<BoneInferenceResponse, Error>]

    init(responses: [Result<BoneInferenceResponse, Error>]) { self.responses = responses }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        guard !responses.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return try responses.removeFirst().get()
    }
}
