import BoneAgentKit
import BoneAgentLocalModels
import XCTest
@testable import BoneAgentLlama

final class BoneLlamaRuntimeModelsTests: XCTestCase {
    func testConfigurationMapsRuntimePlan() {
        let configuration = BoneLlamaRuntimeConfiguration(plan: .init(
            contextTokens: 4_096,
            maximumOutputTokens: 1_024,
            batchTokens: 256,
            threadCount: 6
        ))

        XCTAssertEqual(configuration.contextTokens, 4_096)
        XCTAssertEqual(configuration.batchTokens, 256)
        XCTAssertEqual(configuration.threadCount, 6)
    }

    func testGenerationOptionsValidateAndClampToPlan() throws {
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: .init(temperature: 1.5, maximumOutputTokens: 2_048),
            plan: .init(
                contextTokens: 4_096,
                maximumOutputTokens: 512,
                batchTokens: 256,
                threadCount: 4
            )
        )

        XCTAssertEqual(options.temperature, 1.5)
        XCTAssertEqual(options.maximumOutputTokens, 512)
    }

    func testPromptExecutionPlannerAutomaticallySlicesPrefillAndClampsOutput() throws {
        let plan = try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: BoneLlamaPromptTokenization(tokenCount: 600),
            configuration: .init(plan: .init(
                contextTokens: 700,
                maximumOutputTokens: 512,
                batchTokens: 256,
                threadCount: 2
            )),
            requestedMaximumOutputTokens: 512
        )

        XCTAssertEqual(plan.promptTokenCount, 600)
        XCTAssertEqual(plan.maximumOutputTokens, 100)
        XCTAssertEqual(plan.prefillRanges, [0..<256, 256..<512, 512..<600])
        XCTAssertTrue(plan.prefillRanges.allSatisfy { $0.count <= plan.batchTokens })
    }

    func testPromptExecutionPlannerRejectsContextOverflowAndEmptyTokenization() throws {
        XCTAssertThrowsError(try BoneLlamaPromptTokenization(tokenCount: 0)) { error in
            XCTAssertEqual(error as? BoneLlamaRuntimeError, .tokenizationFailed)
        }
        let configuration = BoneLlamaRuntimeConfiguration(plan: .init(
            contextTokens: 512,
            maximumOutputTokens: 128,
            batchTokens: 64,
            threadCount: 2
        ))
        XCTAssertThrowsError(try BoneLlamaPromptExecutionPlanner.plan(
            tokenization: BoneLlamaPromptTokenization(tokenCount: 512),
            configuration: configuration,
            requestedMaximumOutputTokens: 1
        )) { error in
            XCTAssertEqual(error as? BoneLlamaRuntimeError, .promptTooLong)
        }
    }

    func testGenerationOptionsRejectInvalidValues() {
        XCTAssertThrowsError(try BoneLlamaGenerationOptions(
            inferenceOptions: .init(temperature: -1, maximumOutputTokens: 1),
            plan: .init(contextTokens: 512, maximumOutputTokens: 128, batchTokens: 32, threadCount: 1)
        )) { error in
            XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidGenerationOptions)
        }
    }
}
