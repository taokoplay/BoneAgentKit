import BoneAgentKit
import BoneAgentLocalModels
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaGenerationControlTests: XCTestCase {
    func testValidatesAndNormalizesStopControls() throws {
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: [2, 3, 2],
            stopStrings: ["<eog>", "<stop>", "<eog>"],
            constraint: .enumChoice(["yes", "no"])
        )

        XCTAssertEqual(control.stopTokenIDs, [2, 3])
        XCTAssertEqual(control.stopStrings, ["<eog>", "<stop>"])
        XCTAssertEqual(control.constraint, .enumChoice(["yes", "no"]))
        XCTAssertTrue(control.requiresControlledRuntime)
    }

    func testRejectsInvalidStopsAndConstraints() {
        XCTAssertThrowsError(try BoneLlamaGenerationControl(stopStrings: [""]))
        XCTAssertThrowsError(try BoneLlamaGenerationControl(
            stopStrings: [String(repeating: "x", count: BoneLlamaGenerationControl.maximumStopStringByteCount + 1)]
        ))
        XCTAssertThrowsError(try BoneLlamaGenerationControl(
            stopTokenIDs: (0...BoneLlamaGenerationControl.maximumStopTokenCount).map(Int32.init)
        ))
        XCTAssertThrowsError(try BoneLlamaGenerationControl(constraint: .enumChoice([])))
    }

    func testGenerationResultCarriesStableTermination() {
        XCTAssertEqual(
            BoneLlamaGenerationResult(text: "ok", termination: .eog),
            .init(text: "ok", termination: .eog)
        )
        XCTAssertEqual(
            BoneLlamaGenerationResult(text: "partial", termination: .maximumTokens).termination,
            .maximumTokens
        )
    }

    func testControlledRuntimeReceivesControl() async throws {
        let runtime = ControlledGenerationRuntimeFixture()
        let control = try BoneLlamaGenerationControl(stopTokenIDs: [2])
        let plan = try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: .init(tokenCount: 8),
            configuration: .init(plan: .init(contextTokens: 64, maximumOutputTokens: 8, batchTokens: 8, threadCount: 1)),
            requestedMaximumOutputTokens: 8
        )

        _ = try await runtime.generate(
            prompt: "prompt",
            executionPlan: plan,
            options: .init(maximumOutputTokens: 8, temperature: 0),
            control: control
        )

        let received = await runtime.receivedControl()
        XCTAssertEqual(received, control)
    }
}

private actor ControlledGenerationRuntimeFixture: BoneLlamaControlledGenerationRuntime {
    nonisolated let runtimeVersion = 1
    private var control: BoneLlamaGenerationControl?

    func load(modelURL: URL, configuration: BoneLlamaRuntimeConfiguration) async throws {}
    func tokenize(prompt: String) async throws -> BoneLlamaPromptTokenization { try .init(tokenCount: 1) }
    func generate(prompt: String, executionPlan: BoneLlamaPromptExecutionPlan, options: BoneLlamaGenerationOptions) async throws -> BoneLlamaGenerationResult { .init(text: "legacy") }
    func generate(
        prompt: String,
        executionPlan: BoneLlamaPromptExecutionPlan,
        options: BoneLlamaGenerationOptions,
        control: BoneLlamaGenerationControl
    ) async throws -> BoneLlamaGenerationResult {
        self.control = control
        return .init(text: "ok", termination: .eog)
    }
    func verifyBasicGeneration() async throws {}
    func cancel() async {}
    func unload() async {}
    func receivedControl() -> BoneLlamaGenerationControl? { control }
}
