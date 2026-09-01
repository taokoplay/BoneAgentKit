import BoneAgentKit
import BoneAgentLocalRuntime
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaRuntimeProbeAdapterTests: XCTestCase {
    func testLoadProbeLoadsThenUnloadsIsolatedRuntime() async throws {
        let runtime = LlamaRuntimeFixture()
        let adapter = BoneLlamaRuntimeProbeAdapter(
            runtimeVersion: 2,
            runtimeFactory: { runtime }
        )

        let result = await adapter.probe(
            model: try model(),
            artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
            environment: environment(),
            plan: plan(),
            depth: .load
        )

        let events = await runtime.events()
        XCTAssertEqual(result.check, .init(kind: .modelLoad, status: .passed))
        XCTAssertEqual(events, [.load, .unload])
    }

    func testSmokeProbeRunsSmokeAndMapsRuntimeErrors() async throws {
        for (error, expected) in [
            (BoneLlamaRuntimeError.modelIncompatible, BoneLocalRuntimeProbeCheckStatus.incompatible),
            (.insufficientResources, .temporarilyUnavailable),
            (.loadFailed, .failed),
        ] {
            let runtime = LlamaRuntimeFixture(error: error)
            let adapter = BoneLlamaRuntimeProbeAdapter(runtimeVersion: 1, runtimeFactory: { runtime })
            let result = await adapter.probe(
                model: try model(), artifactURL: URL(fileURLWithPath: "/tmp/model.gguf"),
                environment: environment(), plan: plan(), depth: .smoke
            )
            let events = await runtime.events()
            XCTAssertEqual(result.check, .init(kind: .smoke, status: expected))
            XCTAssertEqual(events.last, .unload)
        }
    }

    private func plan() -> BoneLocalRuntimePlan {
        .init(contextTokens: 512, maximumOutputTokens: 128, batchTokens: 32, threadCount: 2)
    }

    private func environment() -> BoneLocalRuntimeEnvironment {
        .init(physicalMemoryBytes: 10_000, availableDiskBytes: 10_000, activeProcessorCount: 4, isSimulator: false, isLowPowerModeEnabled: false, thermalState: .nominal)
    }

    private func model() throws -> BoneLocalModelDescriptor {
        .init(
            id: "model", displayName: "Model", family: "Test", format: .gguf,
            parameterCount: 1, quantization: "Q4", minimumMemoryBytes: 1,
            recommendedContextTokens: 512, minimumRuntimeVersion: 1,
            contextLimits: try .init(contextWindowTokens: 1_024, maximumInputTokens: 768, maximumOutputTokens: 256, source: .official, verifiedAt: "2026-09-01", documentationURL: URL(string: "https://example.com")!),
            artifact: .init(fileName: "model.gguf", expectedByteCount: 4, sha256: String(repeating: "a", count: 64), sources: []),
            license: .init(name: "Test", url: URL(string: "https://example.com")!, modelCardURL: URL(string: "https://example.com")!)
        )
    }
}

private enum LlamaRuntimeEvent: Equatable, Sendable { case load, smoke, unload }

private actor LlamaRuntimeFixture: BoneLlamaRuntime {
    nonisolated let runtimeVersion = 1
    private let error: BoneLlamaRuntimeError?
    private var recorded: [LlamaRuntimeEvent] = []

    init(error: BoneLlamaRuntimeError? = nil) { self.error = error }

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {
        recorded.append(.load)
        if let error { throw error }
    }
    func generate(prompt: String, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult { .init(text: "ok") }
    func smokeTest() async throws { recorded.append(.smoke) }
    func cancel() async {}
    func unload() async { recorded.append(.unload) }
    func events() -> [LlamaRuntimeEvent] { recorded }
}
