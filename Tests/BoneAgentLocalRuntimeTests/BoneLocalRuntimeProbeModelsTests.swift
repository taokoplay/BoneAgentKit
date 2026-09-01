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
        XCTAssertEqual(
            BoneLocalRuntimeProbeReport(
                modelID: "model",
                adapterID: "adapter",
                depth: .metadata,
                checks: [.init(kind: .installation, status: .passed)]
            ).status,
            .compatible
        )
    }
}
