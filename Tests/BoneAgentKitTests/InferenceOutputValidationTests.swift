import Foundation
import XCTest
import BoneAgentKit

final class InferenceOutputValidationTests: XCTestCase {
    func testInitialAcceptanceReturnsValidatorValueWithoutCorrection() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Int, String, Void>().process(
            42, policy: .init(maximumCorrectionAttempts: 2),
            validate: { input in
                await trace.append("validate:\(input)")
                return .accepted("value-\(input)")
            },
            correct: { input, _, _ in
                await trace.append("unexpected correction")
                return input
            }
        )
        guard case .accepted(let value) = result.validation else { return XCTFail("Expected acceptance") }
        XCTAssertEqual(value, "value-42")
        assertOutputReceipt(result.receipt, validations: 1, corrections: 0, outcome: .accepted)
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:42"])
    }

    func testDefaultPolicyDisablesEvenExplicitlyCorrectableRejection() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<String, String, String>().process(
            "candidate",
            validate: { _ in
                await trace.append("validate")
                return .rejected(try .init(issue: .invalidFormat, allowsCorrection: true, feedback: "repair"))
            },
            correct: { input, _, _ in
                await trace.append("unexpected correction")
                return input
            }
        )
        guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected rejection") }
        XCTAssertEqual(rejection.feedback, "repair")
        assertOutputReceipt(result.receipt, validations: 1, corrections: 0, outcome: .rejected(.invalidFormat))
        let events = await trace.events()
        XCTAssertEqual(events, ["validate"])
    }

    func testNonCorrectableRejectionStopsWithExecutorAndBudgetAvailable() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
            0, policy: .init(maximumCorrectionAttempts: 3),
            validate: { _ in
                await trace.append("validate")
                return .rejected(try .init(issue: .invalidReference))
            },
            correct: { input, _, _ in
                await trace.append("unexpected correction")
                return input + 1
            }
        )
        guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected rejection") }
        XCTAssertFalse(rejection.allowsCorrection)
        XCTAssertNil(rejection.feedback)
        XCTAssertEqual(rejection.issueCount, 1)
        assertOutputReceipt(result.receipt, validations: 1, corrections: 0, outcome: .rejected(.invalidReference))
        let events = await trace.events()
        XCTAssertEqual(events, ["validate"])
    }

    func testMissingExecutorReturnsCorrectableRejection() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Data, Bool, Void>().process(
            Data(), policy: .init(maximumCorrectionAttempts: 2),
            validate: { _ in
                await trace.append("validate")
                return .rejected(try .init(issue: .missingRequiredOutput, issueCount: 2, allowsCorrection: true))
            }
        )
        guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected rejection") }
        XCTAssertEqual(rejection.issueCount, 2)
        XCTAssertTrue(rejection.allowsCorrection)
        assertOutputReceipt(result.receipt, validations: 1, corrections: 0, outcome: .rejected(.missingRequiredOutput))
        let events = await trace.events()
        XCTAssertEqual(events, ["validate"])
    }

    func testPolicyBoundariesReserveSpaceForInitialValidation() throws {
        XCTAssertEqual(BoneInferenceOutputCorrectionPolicy().maximumCorrectionAttempts, 0)
        for attempts in [0, 1, Int.max - 1] {
            XCTAssertEqual(try BoneInferenceOutputCorrectionPolicy(maximumCorrectionAttempts: attempts)
                .maximumCorrectionAttempts, attempts)
        }
        for attempts in [Int.min, -1, Int.max] {
            XCTAssertThrowsError(try BoneInferenceOutputCorrectionPolicy(maximumCorrectionAttempts: attempts)) {
                XCTAssertEqual($0 as? BoneInferenceOutputCorrectionPolicy.Error, .invalidMaximumCorrectionAttempts)
            }
        }
    }

    func testRejectionIssueCountBoundariesAndDefaults() throws {
        XCTAssertEqual(BoneInferenceOutputRejection<Void>.maximumIssueCount, 65_535)
        for count in [1, 65_535] {
            let rejection = try BoneInferenceOutputRejection<Void>(issue: .other, issueCount: count)
            XCTAssertEqual(rejection.issueCount, count)
            XCTAssertFalse(rejection.allowsCorrection)
            XCTAssertNil(rejection.feedback)
        }
        for count in [Int.min, -1, 0, 65_536, Int.max] {
            XCTAssertThrowsError(try BoneInferenceOutputRejection<Void>(issue: .other, issueCount: count)) {
                XCTAssertEqual($0 as? BoneInferenceOutputRejection<Void>.Error, .invalidIssueCount)
            }
        }
    }

    func testValidatorMayAcceptEmptyOptionalArrayAndVoidValues() async throws {
        let optional = try await BoneInferenceValidatedOutputProcessor<String, String?, Void>()
            .process("") { input in
                XCTAssertTrue(input.isEmpty)
                return .accepted(nil)
            }
        guard case .accepted(let value) = optional.validation else { return XCTFail("Expected nil acceptance") }
        XCTAssertNil(value)
        assertOutputReceipt(optional.receipt, validations: 1, corrections: 0, outcome: .accepted)

        let array = try await BoneInferenceValidatedOutputProcessor<Data, [Int], Void>()
            .process(Data()) { _ in .accepted([]) }
        guard case .accepted(let values) = array.validation else { return XCTFail("Expected empty array") }
        XCTAssertTrue(values.isEmpty)
        assertOutputReceipt(array.receipt, validations: 1, corrections: 0, outcome: .accepted)

        let void = try await BoneInferenceValidatedOutputProcessor<Void, Void, Void>()
            .process(()) { _ in .accepted(()) }
        guard case .accepted = void.validation else { return XCTFail("Expected Void acceptance") }
        assertOutputReceipt(void.receipt, validations: 1, corrections: 0, outcome: .accepted)
    }

    func testPrivateFeedbackReachesCorrectionAndFinalRejectionButNotReceipt() async throws {
        let secret = "CANARY-feedback-field-path-and-body"
        let feedback = PrivateFeedback(field: secret, values: [secret])
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<String, String, PrivateFeedback>().process(
            secret, policy: .init(maximumCorrectionAttempts: 1),
            validate: { input in
                XCTAssertTrue(input.contains(secret))
                return .rejected(try .init(issue: .contractMismatch, issueCount: 7,
                    allowsCorrection: true, feedback: feedback))
            },
            correct: { input, rejection, attempt in
                XCTAssertEqual(input, secret)
                XCTAssertEqual(rejection.feedback, feedback)
                XCTAssertEqual(attempt, 1)
                await trace.append("correct")
                return input + "-revised"
            }
        )
        guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected final rejection") }
        XCTAssertEqual(rejection.feedback, feedback)
        XCTAssertEqual(rejection.issueCount, 7)
        assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .rejected(.contractMismatch))
        try assertReceiptExcludes(result.receipt, secret: secret)
        let events = await trace.events()
        XCTAssertEqual(events, ["correct"])

        let accepted = try await BoneInferenceValidatedOutputProcessor<String, String, PrivateFeedback>()
            .process(secret) { .accepted($0) }
        guard case .accepted(let value) = accepted.validation else { return XCTFail("Expected private value") }
        XCTAssertEqual(value, secret)
        try assertReceiptExcludes(accepted.receipt, secret: secret)
    }

    func testSDKConfigurationErrorsContainNoPrivateFeedback() {
        let secret = "CANARY-private-configuration-context"
        XCTAssertThrowsError(try BoneInferenceOutputRejection<String>(issue: .other, issueCount: 0,
            allowsCorrection: true, feedback: secret)) { error in
            XCTAssertEqual(error as? BoneInferenceOutputRejection<String>.Error, .invalidIssueCount)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
        XCTAssertThrowsError(try BoneInferenceOutputCorrectionPolicy(maximumCorrectionAttempts: -1)) { error in
            XCTAssertEqual(error as? BoneInferenceOutputCorrectionPolicy.Error, .invalidMaximumCorrectionAttempts)
            XCTAssertFalse(String(describing: error).contains(secret))
            XCTAssertFalse(String(reflecting: error).contains(secret))
        }
    }

    private struct PrivateFeedback: Equatable, Sendable {
        let field: String
        let values: [String]
    }

    private func assertReceiptExcludes(_ receipt: BoneInferenceOutputProcessingReceipt, secret: String) throws {
        let data = try JSONEncoder().encode(receipt)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(String(describing: receipt).contains(secret))
        XCTAssertFalse(String(reflecting: receipt).contains(secret))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["validationCount", "correctionAttemptCount", "outcome"])
        XCTAssertEqual(object["validationCount"] as? Int, receipt.validationCount)
        XCTAssertEqual(object["correctionAttemptCount"] as? Int, receipt.correctionAttemptCount)
    }
}

// Shared test-only helpers keep async observations outside XCTest autoclosures.
actor OutputValidationTestTrace {
    private var recorded: [String] = []
    func append(_ event: String) { recorded.append(event) }
    func events() -> [String] { recorded }
}

func assertOutputReceipt(
    _ receipt: BoneInferenceOutputProcessingReceipt,
    validations: Int,
    corrections: Int,
    outcome: BoneInferenceOutputProcessingReceipt.Outcome,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertEqual(receipt.validationCount, validations, file: file, line: line)
    XCTAssertEqual(receipt.correctionAttemptCount, corrections, file: file, line: line)
    XCTAssertEqual(receipt.usedCorrection, corrections > 0, file: file, line: line)
    XCTAssertEqual(receipt.outcome, outcome, file: file, line: line)
}
