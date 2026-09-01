import BoneAgentKit
import BoneAgentLocalRuntime
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

    func testGenerationOptionsRejectInvalidValues() {
        XCTAssertThrowsError(try BoneLlamaGenerationOptions(
            inferenceOptions: .init(temperature: -1, maximumOutputTokens: 1),
            plan: .init(contextTokens: 512, maximumOutputTokens: 128, batchTokens: 32, threadCount: 1)
        )) { error in
            XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidGenerationOptions)
        }
    }
}
