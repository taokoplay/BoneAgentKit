import CryptoKit
import XCTest
@testable import BoneAgentLocalRuntime

final class BoneLocalRuntimeProbeCoordinatorTests: XCTestCase {
    func testMetadataProbeDoesNotInvokeAdapterAndReturnsCompatibleReport() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let adapter = ProbeAdapterFixture(result: .init(
            check: .init(kind: .modelLoad, status: .passed)
        ))
        let coordinator = BoneLocalRuntimeProbeCoordinator(store: context.store)

        let report = await coordinator.probe(
            model: context.model,
            environment: environment(memory: 10_000),
            adapter: adapter,
            depth: .metadata,
            verifyChecksum: true
        )

        let invocationCount = await adapter.invocationCount()
        XCTAssertEqual(report.status, .compatible)
        XCTAssertEqual(invocationCount, 0)
        XCTAssertEqual(report.checks.map(\.kind), [
            .installation, .artifactIntegrity, .formatSignature,
            .adapterFormatCompatibility, .runtimeVersion,
            .deviceMemory, .runtimePlan,
        ])
    }

    func testLoadProbeInvokesAdapterWithPlan() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let adapter = ProbeAdapterFixture(result: .init(
            check: .init(kind: .modelLoad, status: .passed)
        ))
        let coordinator = BoneLocalRuntimeProbeCoordinator(store: context.store)

        let report = await coordinator.probe(
            model: context.model,
            environment: environment(memory: 10_000),
            adapter: adapter,
            depth: .load,
            verifyChecksum: false
        )

        let invocationCount = await adapter.invocationCount()
        XCTAssertEqual(report.status, .compatible)
        XCTAssertEqual(invocationCount, 1)
        XCTAssertEqual(report.checks.last, .init(kind: .modelLoad, status: .passed))
    }

    func testStaticFailuresDoNotInvokeAdapter() async throws {
        let cases: [(adapter: ProbeAdapterFixture, environment: BoneLocalRuntimeEnvironment, expected: BoneLocalRuntimeProbeStatus)] = [
            (ProbeAdapterFixture(supportedFormats: [], result: passed()), environment(memory: 10_000), .incompatible),
            (ProbeAdapterFixture(runtimeVersion: 0, result: passed()), environment(memory: 10_000), .incompatible),
            (ProbeAdapterFixture(result: passed()), environment(memory: 0), .temporarilyUnavailable),
            (ProbeAdapterFixture(maximumDepth: .metadata, result: passed()), environment(memory: 10_000), .unsupported),
        ]
        for item in cases {
            let context = try makeContext()
            defer { try? FileManager.default.removeItem(at: context.root) }
            let report = await BoneLocalRuntimeProbeCoordinator(store: context.store).probe(
                model: context.model,
                environment: item.environment,
                adapter: item.adapter,
                depth: .load,
                verifyChecksum: false
            )
            let invocationCount = await item.adapter.invocationCount()
            XCTAssertEqual(report.status, item.expected)
            XCTAssertEqual(invocationCount, 0)
        }
    }

    private static func passed() -> BoneLocalRuntimeAdapterProbeResult {
        .init(check: .init(kind: .modelLoad, status: .passed))
    }

    private func passed() -> BoneLocalRuntimeAdapterProbeResult { Self.passed() }

    private func makeContext() throws -> (
        root: URL,
        store: BoneLocalModelStore,
        model: BoneLocalModelDescriptor
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("GGUFmodel".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let model = BoneLocalModelDescriptor(
            id: "model", displayName: "Model", family: "Test", format: .gguf,
            parameterCount: 1, quantization: "Q4", minimumMemoryBytes: 1_000,
            recommendedContextTokens: 512, minimumRuntimeVersion: 1,
            contextLimits: try .init(
                contextWindowTokens: 1_024, maximumInputTokens: 768,
                maximumOutputTokens: 256, source: .official, verifiedAt: "2026-09-01",
                documentationURL: URL(string: "https://example.com/model")!
            ),
            artifact: .init(
                fileName: "model.gguf", expectedByteCount: Int64(payload.count), sha256: hash,
                sources: [.init(id: "source", url: URL(string: "https://models.example.com/model")!, allowedHosts: ["models.example.com"], priority: 1)]
            ),
            license: .init(name: "Test", url: URL(string: "https://example.com/license")!, modelCardURL: URL(string: "https://example.com/model")!)
        )
        let store = try BoneLocalModelStore(rootURL: root.appendingPathComponent("models"))
        let source = root.appendingPathComponent("source")
        try payload.write(to: source)
        _ = try store.installDownloadedFile(at: source, for: model)
        return (root, store, model)
    }

    private func environment(memory: UInt64) -> BoneLocalRuntimeEnvironment {
        .init(
            physicalMemoryBytes: memory, availableDiskBytes: 10_000,
            activeProcessorCount: 4, isSimulator: false,
            isLowPowerModeEnabled: false, thermalState: .nominal
        )
    }
}

private actor ProbeAdapterFixture: BoneLocalRuntimeAdapterProbing {
    nonisolated let descriptor: BoneLocalRuntimeAdapterDescriptor
    private let result: BoneLocalRuntimeAdapterProbeResult
    private var count = 0

    init(
        runtimeVersion: Int = 1,
        supportedFormats: Set<BoneLocalModelFormat> = [.gguf],
        maximumDepth: BoneLocalRuntimeProbeDepth = .load,
        result: BoneLocalRuntimeAdapterProbeResult
    ) {
        descriptor = .init(
            id: "adapter", runtimeVersion: runtimeVersion,
            supportedFormats: supportedFormats,
            runtimeConstraints: .init(
                maximumContextTokens: 1_024, maximumOutputTokens: 256,
                maximumBatchTokens: 128, maximumThreadCount: 4
            ),
            maximumProbeDepth: maximumDepth
        )
        self.result = result
    }

    func probe(
        model: BoneLocalModelDescriptor,
        artifactURL: URL,
        environment: BoneLocalRuntimeEnvironment,
        plan: BoneLocalRuntimePlan,
        depth: BoneLocalRuntimeProbeDepth
    ) async -> BoneLocalRuntimeAdapterProbeResult {
        count += 1
        return result
    }

    func invocationCount() -> Int { count }
}
