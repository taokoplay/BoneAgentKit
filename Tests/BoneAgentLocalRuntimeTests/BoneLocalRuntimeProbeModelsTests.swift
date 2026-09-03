import BoneAgentKit
import XCTest
@testable import BoneAgentLocalRuntime

final class BoneLocalRuntimeProbeModelsTests: XCTestCase {
    func testProbeDepthOrderingAndAdapterSupport() {
        XCTAssertLessThan(BoneLocalRuntimeProbeDepth.metadata, .load)
        XCTAssertLessThan(BoneLocalRuntimeProbeDepth.load, .smoke)

        let adapter = BoneLocalRuntimeAdapterDescriptor(
            id: "llama",
            runtimeVersion: 2,
            supportedFormats: [.gguf],
            runtimeConstraints: .init(
                maximumContextTokens: 8_192,
                maximumOutputTokens: 2_048,
                maximumBatchTokens: 512,
                maximumThreadCount: 4
            ),
            maximumProbeDepth: .load
        )
        XCTAssertTrue(adapter.supports(.metadata))
        XCTAssertTrue(adapter.supports(.load))
        XCTAssertFalse(adapter.supports(.smoke))
    }

    func testReportAggregatesMostSevereCheckFailClosed() {
        let report = BoneLocalRuntimeProbeReport(
            modelID: "model",
            adapterID: "llama",
            depth: .load,
            checks: [
                .init(kind: .installation, status: .passed),
                .init(kind: .deviceMemory, status: .temporarilyUnavailable),
                .init(kind: .modelLoad, status: .incompatible),
            ]
        )

        XCTAssertEqual(report.status, .incompatible)
        XCTAssertEqual(report.checks.map(\.kind), [.installation, .deviceMemory, .modelLoad])
        XCTAssertTrue(report.verifiedCapabilities.isEmpty)
    }

    func testProbeResultCarriesVerificationIdentityWithoutPayloadContent() throws {
        let identity = try BoneCapabilityVerificationIdentity(
            artifactSHA256: String(repeating: "a", count: 64),
            runtimeID: "llama.cpp",
            runtimeVersion: 2,
            tokenizerID: "gguf",
            tokenizerVersion: "1",
            templateDigest: String(repeating: "b", count: 64),
            rendererID: "native",
            rendererVersion: "1",
            reasoningMode: "disabled",
            generationControlDigest: String(repeating: "c", count: 64),
            toolEnvelopeID: nil,
            toolEnvelopeVersion: nil,
            constraintDecoderID: nil,
            constraintDecoderVersion: nil,
            contextTokens: 4096,
            batchTokens: 256
        )
        let result = BoneLocalRuntimeAdapterProbeResult(
            check: .init(kind: .smoke, status: .passed),
            verifiedCapabilities: [.text],
            verificationIdentity: identity
        )

        XCTAssertEqual(result.verificationIdentity, identity)
    }

    func testCompatibleRequiresNonemptyAllPassedChecks() {
        XCTAssertEqual(
            BoneLocalRuntimeProbeReport(
                modelID: "model",
                adapterID: "adapter",
                depth: .metadata,
                checks: []
            ).status,
            .failed
        )
        let compatible = BoneLocalRuntimeProbeReport(
            modelID: "model",
            adapterID: "adapter",
            depth: .smoke,
            checks: [.init(kind: .smoke, status: .passed)],
            verifiedCapabilities: [.text]
        )
        XCTAssertEqual(compatible.status, .compatible)
        XCTAssertEqual(compatible.verifiedCapabilities, [.text])
    }
}
