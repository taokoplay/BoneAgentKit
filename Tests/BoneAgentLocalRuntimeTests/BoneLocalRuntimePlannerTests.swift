import BoneAgentKit
import XCTest
@testable import BoneAgentLocalRuntime

final class BoneLocalRuntimePlannerTests: XCTestCase {
    func testPlannerClampsModelRuntimeAndHostLimits() throws {
        let model = try descriptor(contextWindow: 32_768, recommended: 8_192, minimumMemory: 4_000)
        let environment = BoneLocalRuntimeEnvironment(
            physicalMemoryBytes: 16_000,
            availableDiskBytes: 50_000,
            activeProcessorCount: 8,
            isSimulator: false,
            isLowPowerModeEnabled: false,
            thermalState: .nominal
        )
        let constraints = BoneLocalRuntimeConstraints(
            maximumContextTokens: 16_384,
            maximumOutputTokens: 2_048,
            maximumBatchTokens: 512,
            maximumThreadCount: 6
        )

        let plan = try BoneLocalRuntimePlanner.plan(
            model: model,
            environment: environment,
            runtimeConstraints: constraints,
            request: .init(
                requestedContextTokens: 12_000,
                requestedOutputTokens: 4_096,
                requestedBatchTokens: 1_024,
                requestedThreadCount: 8,
                hostMaximumContextTokens: 6_000
            )
        )

        XCTAssertEqual(plan.contextTokens, 6_000)
        XCTAssertEqual(plan.maximumOutputTokens, 2_048)
        XCTAssertEqual(plan.batchTokens, 512)
        XCTAssertEqual(plan.threadCount, 6)
    }

    func testPlannerUsesConservativeDefaultsInLowPowerAndSeriousThermalState() throws {
        let model = try descriptor(contextWindow: 8_192, recommended: 4_096, minimumMemory: 4_000)
        let environment = BoneLocalRuntimeEnvironment(
            physicalMemoryBytes: 8_000,
            availableDiskBytes: 10_000,
            activeProcessorCount: 8,
            isSimulator: false,
            isLowPowerModeEnabled: true,
            thermalState: .serious
        )
        let plan = try BoneLocalRuntimePlanner.plan(
            model: model,
            environment: environment,
            runtimeConstraints: .init(
                maximumContextTokens: 8_192,
                maximumOutputTokens: 1_024,
                maximumBatchTokens: 512,
                maximumThreadCount: 8
            )
        )

        XCTAssertEqual(plan.contextTokens, 4_096)
        XCTAssertEqual(plan.batchTokens, 128)
        XCTAssertEqual(plan.threadCount, 2)
    }

    func testPlannerRejectsInsufficientMemory() throws {
        let model = try descriptor(contextWindow: 8_192, recommended: 4_096, minimumMemory: 8_000)
        let environment = BoneLocalRuntimeEnvironment(
            physicalMemoryBytes: 4_000,
            availableDiskBytes: 10_000,
            activeProcessorCount: 4,
            isSimulator: false,
            isLowPowerModeEnabled: false,
            thermalState: .nominal
        )
        XCTAssertThrowsError(
            try BoneLocalRuntimePlanner.plan(
                model: model,
                environment: environment,
                runtimeConstraints: .init(
                    maximumContextTokens: 8_192,
                    maximumOutputTokens: 1_024,
                    maximumBatchTokens: 256,
                    maximumThreadCount: 4
                )
            )
        ) { error in
            XCTAssertEqual(error as? BoneLocalRuntimePlanningError, .insufficientMemory(required: 8_000, available: 4_000))
        }
    }

    private func descriptor(
        contextWindow: Int,
        recommended: Int,
        minimumMemory: UInt64
    ) throws -> BoneLocalModelDescriptor {
        let limits = try BoneModelContextLimits(
            contextWindowTokens: contextWindow,
            maximumInputTokens: nil,
            maximumOutputTokens: 4_096,
            source: .official,
            verifiedAt: "2026-09-01",
            documentationURL: URL(string: "https://example.com/model")!
        )
        return BoneLocalModelDescriptor(
            id: "model",
            displayName: "Model",
            family: "Test",
            format: .gguf,
            parameterCount: 1_000,
            quantization: "Q4",
            minimumMemoryBytes: minimumMemory,
            recommendedContextTokens: recommended,
            minimumRuntimeVersion: 1,
            contextLimits: limits,
            artifact: .init(
                fileName: "model.gguf",
                expectedByteCount: 1,
                sha256: String(repeating: "a", count: 64),
                sources: []
            ),
            license: .init(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                modelCardURL: URL(string: "https://example.com/model")!
            )
        )
    }
}
