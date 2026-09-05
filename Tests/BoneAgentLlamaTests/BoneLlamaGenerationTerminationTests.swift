import XCTest
@testable import BoneAgentLlama

final class BoneLlamaGenerationTerminationTests: XCTestCase {
    func testAcceptsExactConfiguredStopEvidence() throws {
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: [2, 3],
            stopStrings: ["<eog>", "<stop>"]
        )

        XCTAssertNoThrow(try BoneLlamaTerminationValidator.validate(
            .stopToken(id: 3), control: control, requiresCompleteOutput: true
        ))
        XCTAssertNoThrow(try BoneLlamaTerminationValidator.validate(
            .stopString(index: 1), control: control, requiresCompleteOutput: true
        ))
    }

    func testRejectsForgedOrOutOfRangeStopEvidence() throws {
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: [2],
            stopStrings: ["<eog>"]
        )

        for termination in [
            BoneLlamaGenerationTermination.stopToken(id: 99),
            .stopString(index: -1),
            .stopString(index: 1),
        ] {
            XCTAssertThrowsError(try BoneLlamaTerminationValidator.validate(
                termination, control: control, requiresCompleteOutput: true
            )) { error in
                XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidToolCallingResponse)
            }
        }
    }

    func testAppliesCompleteOutputTerminationContract() throws {
        let control = try BoneLlamaGenerationControl()
        XCTAssertNoThrow(try BoneLlamaTerminationValidator.validate(
            .eog, control: control, requiresCompleteOutput: true
        ))
        XCTAssertThrowsError(try BoneLlamaTerminationValidator.validate(
            .maximumTokens, control: control, requiresCompleteOutput: true
        )) { error in
            XCTAssertEqual(error as? BoneLlamaAdapterError, .outputTruncated)
        }
        XCTAssertThrowsError(try BoneLlamaTerminationValidator.validate(
            .runtimeCompleted, control: control, requiresCompleteOutput: true
        )) { error in
            XCTAssertEqual(error as? BoneLlamaAdapterError, .invalidToolCallingResponse)
        }
    }

    func testTextOnlyRuntimeCompletedRemainsCompatible() throws {
        XCTAssertNoThrow(try BoneLlamaTerminationValidator.validate(
            .runtimeCompleted,
            control: BoneLlamaGenerationControl(),
            requiresCompleteOutput: false
        ))
    }

    func testTerminationCodableRoundTripsEvidence() throws {
        for value in [
            BoneLlamaGenerationTermination.eog,
            .stopToken(id: 2),
            .stopString(index: 1),
            .maximumTokens,
            .runtimeCompleted,
        ] {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(BoneLlamaGenerationTermination.self, from: data), value)
        }
    }
}
