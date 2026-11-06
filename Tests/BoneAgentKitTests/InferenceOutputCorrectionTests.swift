import Foundation
import XCTest
import BoneAgentKit

final class InferenceOutputCorrectionTests: XCTestCase {
    func testSingleCorrectionSucceedsAndReturnsValidatorValue() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Int, String, String>().process(
            0, policy: .init(maximumCorrectionAttempts: 1),
            validate: { candidate in
                await trace.append("validate:\(candidate)")
                if candidate == 1 { return .accepted("validated-one") }
                return .rejected(try .init(issue: .invalidFormat, allowsCorrection: true, feedback: "increment"))
            },
            correct: { candidate, rejection, attempt in
                XCTAssertEqual(rejection.feedback, "increment")
                XCTAssertEqual(attempt, 1)
                await trace.append("correct:\(candidate)")
                return candidate + 1
            }
        )
        guard case .accepted(let value) = result.validation else { return XCTFail("Expected acceptance") }
        XCTAssertEqual(value, "validated-one")
        assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .accepted)
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:0", "correct:0", "validate:1"])
    }

    func testSingleCorrectionFailureReturnsLastReport() async throws {
        try await assertExhaustion(maximumAttempts: 1)
    }

    func testFormatAndBusinessIssuesShareLimitWithNoThirdCorrection() async throws {
        try await assertExhaustion(maximumAttempts: 2)
    }

    private func assertExhaustion(maximumAttempts: Int) async throws {
        let trace = OutputValidationTestTrace()
        let issues: [BoneInferenceOutputIssue] = [.invalidFormat, .contractMismatch, .invalidReference]
        let result = try await BoneInferenceValidatedOutputProcessor<Int, String, String>().process(
            0, policy: .init(maximumCorrectionAttempts: maximumAttempts),
            validate: { candidate in
                await trace.append("validate:\(candidate)")
                return .rejected(try .init(issue: issues[min(candidate, 2)], issueCount: candidate + 1,
                    allowsCorrection: true, feedback: "feedback-\(candidate)"))
            },
            correct: { candidate, rejection, attempt in
                XCTAssertEqual(attempt, candidate + 1)
                XCTAssertEqual(rejection.issue, issues[min(candidate, 2)])
                XCTAssertEqual(rejection.issueCount, candidate + 1)
                XCTAssertEqual(rejection.feedback, "feedback-\(candidate)")
                await trace.append("correct:\(candidate):\(attempt)")
                return candidate + 1
            }
        )
        guard case .rejected(let last) = result.validation else { return XCTFail("Expected exhausted rejection") }
        XCTAssertEqual(last.issue, issues[maximumAttempts])
        XCTAssertEqual(last.issueCount, maximumAttempts + 1)
        XCTAssertEqual(last.feedback, "feedback-\(maximumAttempts)")
        XCTAssertTrue(last.allowsCorrection)
        assertOutputReceipt(result.receipt, validations: maximumAttempts + 1,
            corrections: maximumAttempts, outcome: .rejected(issues[maximumAttempts]))
        var expected: [String] = []
        for candidate in 0..<maximumAttempts {
            expected += ["validate:\(candidate)", "correct:\(candidate):\(candidate + 1)"]
        }
        expected.append("validate:\(maximumAttempts)")
        let events = await trace.events()
        XCTAssertEqual(events, expected)
    }

    func testMultipleCorrectionsUseCurrentCandidateLatestFeedbackAndOneBasedAttempt() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Int, String, Int>().process(
            10, policy: .init(maximumCorrectionAttempts: 4),
            validate: { candidate in
                await trace.append("validate:\(candidate)")
                if candidate == 13 { return .accepted("final-13") }
                return .rejected(try .init(issue: .missingRequiredOutput, issueCount: candidate,
                    allowsCorrection: true, feedback: candidate * 10))
            },
            correct: { candidate, rejection, attempt in
                XCTAssertEqual(candidate, 9 + attempt)
                XCTAssertEqual(rejection.feedback, candidate * 10)
                XCTAssertEqual(rejection.issueCount, candidate)
                await trace.append("correct:\(candidate):\(attempt)")
                return candidate + 1
            }
        )
        guard case .accepted(let value) = result.validation else { return XCTFail("Expected acceptance") }
        XCTAssertEqual(value, "final-13")
        assertOutputReceipt(result.receipt, validations: 4, corrections: 3, outcome: .accepted)
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:10", "correct:10:1", "validate:11", "correct:11:2",
            "validate:12", "correct:12:3", "validate:13"])
    }

    func testLatestNonCorrectableReportStopsRemainingAllowance() async throws {
        let trace = OutputValidationTestTrace()
        let result = try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
            0, policy: .init(maximumCorrectionAttempts: 5),
            validate: { candidate in
                await trace.append("validate:\(candidate)")
                return .rejected(try .init(issue: candidate == 0 ? .invalidFormat : .other,
                    allowsCorrection: candidate == 0))
            },
            correct: { candidate, _, _ in
                await trace.append("correct")
                return candidate + 1
            }
        )
        assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .rejected(.other))
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:0", "correct", "validate:1"])
    }

    func testExternalNetworkAuthorizationStorageAndUnknownErrorsPropagateFromBothClosures() async throws {
        try await assertUnwrapped(BoneInferenceTransportError.network(.init(domain: NSURLErrorDomain, code: -1009)))
        try await assertUnwrapped(BoneAuthorizationError.denied)
        try await assertUnwrapped(BoneContextHistoryPersistenceError.revisionConflict)
        try await assertUnwrapped(BoneContextHistoryPersistenceError.outcomeUnknown)
        try await assertUnwrapped(BoneAgentError.toolOutcomeUnknown)
    }

    private func assertUnwrapped<E: Error & Equatable & Sendable>(_ expected: E) async throws {
        for throwFromValidator in [true, false] {
            let trace = OutputValidationTestTrace()
            do {
                _ = try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
                    0, policy: .init(maximumCorrectionAttempts: 3),
                    validate: { _ in
                        await trace.append("validate")
                        if throwFromValidator { throw expected }
                        return .rejected(try .init(issue: .other, allowsCorrection: true))
                    },
                    correct: { _, _, _ in
                        await trace.append("correct")
                        throw expected
                    }
                )
                XCTFail("Thrown errors must not produce a result or receipt")
            } catch {
                XCTAssertEqual(error as? E, expected)
            }
            let events = await trace.events()
            XCTAssertEqual(events, throwFromValidator ? ["validate"] : ["validate", "correct"])
        }
    }

    func testPrivateExternalErrorPreservesIdentityAndPrivateFieldWithoutRepackaging() async throws {
        let original = PrivateExternalError(privateBody: "CANARY-private-external-error")
        for throwFromValidator in [true, false] {
            let trace = OutputValidationTestTrace()
            do {
                _ = try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
                    0, policy: .init(maximumCorrectionAttempts: 2),
                    validate: { _ in
                        await trace.append("validate")
                        if throwFromValidator { throw original }
                        return .rejected(try .init(issue: .other, allowsCorrection: true))
                    },
                    correct: { _, _, _ in
                        await trace.append("correct")
                        throw original
                    }
                )
                XCTFail("Expected original error, no receipt")
            } catch {
                let received = try XCTUnwrap(error as? PrivateExternalError)
                XCTAssertTrue(received === original)
                XCTAssertEqual(received.privateBody, original.privateBody)
                // External errors are preserved, not claimed to be sanitized by the SDK.
                XCTAssertTrue(String(describing: error).contains(original.privateBody))
            }
            let events = await trace.events()
            XCTAssertEqual(events, throwFromValidator ? ["validate"] : ["validate", "correct"])
        }
    }

    func testCancellationBeforeProcessCallsNeitherClosure() async throws {
        let trace = OutputValidationTestTrace()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
                0, policy: .init(maximumCorrectionAttempts: 1),
                validate: { _ in
                    await trace.append("validate")
                    return .rejected(try .init(issue: .other, allowsCorrection: true))
                },
                correct: { input, _, _ in
                    await trace.append("correct")
                    return input
                }
            )
        }
        do { _ = try await task.value; XCTFail("Expected cancellation, no receipt") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events()
        XCTAssertEqual(events, [])
    }

    func testCancellationWhileValidatorSuspendedDiscardsAcceptedValue() async throws {
        try await assertCancelledValidator(accepts: true)
    }

    func testCancellationWhileValidatorSuspendedDoesNotCorrectRejectedValue() async throws {
        try await assertCancelledValidator(accepts: false)
    }

    private func assertCancelledValidator(accepts: Bool) async throws {
        let trace = OutputValidationTestTrace()
        let gate = OutputCorrectionGate()
        let task = Task {
            try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
                0, policy: .init(maximumCorrectionAttempts: 1),
                validate: { input in
                    await trace.append("validate:start")
                    await gate.suspend()
                    await trace.append("validate:return")
                    if accepts { return .accepted(input) }
                    return .rejected(try .init(issue: .other, allowsCorrection: true))
                },
                correct: { input, _, _ in
                    await trace.append("unexpected correction")
                    return input
                }
            )
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled validation must not return a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:start", "validate:return"])
    }

    func testCancellationWhileCorrectionSuspendedDoesNotValidateNewCandidate() async throws {
        let trace = OutputValidationTestTrace()
        let gate = OutputCorrectionGate()
        let task = Task {
            try await BoneInferenceValidatedOutputProcessor<Int, Int, Void>().process(
                0, policy: .init(maximumCorrectionAttempts: 2),
                validate: { candidate in
                    await trace.append("validate:\(candidate)")
                    if candidate == 1 { return .accepted(candidate) }
                    return .rejected(try .init(issue: .other, allowsCorrection: true))
                },
                correct: { _, _, attempt in
                    await trace.append("correct:start:\(attempt)")
                    await gate.suspend()
                    await trace.append("correct:return")
                    return 1
                }
            )
        }
        await gate.waitUntilSuspended()
        task.cancel()
        await gate.release()
        do { _ = try await task.value; XCTFail("Cancelled correction must not return a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:0", "correct:start:1", "correct:return"])
    }

    func testRepeatedCallsHaveFreshAllowanceAfterExhaustion() async throws {
        let processor = BoneInferenceValidatedOutputProcessor<Int, Int, Void>()
        let trace = OutputValidationTestTrace()
        for invocation in 0..<3 {
            let result = try await processor.process(0, policy: .init(maximumCorrectionAttempts: 1),
                validate: { _ in .rejected(try .init(issue: .other, allowsCorrection: true)) },
                correct: { candidate, _, attempt in
                    await trace.append("\(invocation):\(candidate):\(attempt)")
                    return candidate + 1
                })
            assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .rejected(.other))
        }
        let events = await trace.events()
        XCTAssertEqual(events, ["0:0:1", "1:0:1", "2:0:1"])
    }

    func testConcurrentReuseKeepsCandidatesFeedbackAndCountersIsolated() async throws {
        let processor = BoneInferenceValidatedOutputProcessor<Candidate, String, Candidate>()
        let trace = OutputValidationTestTrace()
        let gate = OutputCorrectionGate(expectedArrivals: 8)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<8 {
                group.addTask {
                    let goal = id % 3 + 1
                    let result = try await processor.process(Candidate(id: id, revision: 0),
                        policy: .init(maximumCorrectionAttempts: 3),
                        validate: { candidate in
                            if candidate.revision == 0 { await gate.suspend() }
                            await trace.append("\(id):validate:\(candidate.revision)")
                            XCTAssertEqual(candidate.id, id)
                            if candidate.revision == goal { return .accepted("accepted-\(id)") }
                            return .rejected(try .init(issue: .contractMismatch,
                                allowsCorrection: true, feedback: candidate))
                        },
                        correct: { candidate, rejection, attempt in
                            XCTAssertEqual(candidate.id, id)
                            XCTAssertEqual(rejection.feedback, candidate)
                            XCTAssertEqual(attempt, candidate.revision + 1)
                            await trace.append("\(id):correct:\(attempt)")
                            return Candidate(id: id, revision: attempt)
                        })
                    guard case .accepted(let value) = result.validation else { return XCTFail("Expected acceptance") }
                    XCTAssertEqual(value, "accepted-\(id)")
                    assertOutputReceipt(result.receipt, validations: goal + 1, corrections: goal, outcome: .accepted)
                }
            }
            await gate.waitUntilSuspended()
            await gate.release()
            try await group.waitForAll()
        }
        let events = await trace.events()
        for id in 0..<8 {
            let goal = id % 3 + 1
            var expected = ["\(id):validate:0"]
            for attempt in 1...goal {
                expected += ["\(id):correct:\(attempt)", "\(id):validate:\(attempt)"]
            }
            XCTAssertEqual(events.filter { $0.hasPrefix("\(id):") }, expected)
        }
    }

    private struct Candidate: Equatable, Sendable {
        let id: Int
        let revision: Int
    }

    private final class PrivateExternalError: Error, Sendable, CustomStringConvertible {
        let privateBody: String
        init(privateBody: String) { self.privateBody = privateBody }
        var description: String { "External failure: \(privateBody)" }
    }
}

// Deliberately ignores cancellation until released, exercising checks after an external await.
private actor OutputCorrectionGate {
    private let expectedArrivals: Int
    private var suspended: [CheckedContinuation<Void, Never>] = []
    private var observer: CheckedContinuation<Void, Never>?

    init(expectedArrivals: Int = 1) { self.expectedArrivals = expectedArrivals }

    func suspend() async {
        await withCheckedContinuation { continuation in
            suspended.append(continuation)
            if suspended.count == expectedArrivals {
                observer?.resume()
                observer = nil
            }
        }
    }

    func waitUntilSuspended() async {
        if suspended.count >= expectedArrivals { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        let continuations = suspended
        suspended.removeAll()
        for continuation in continuations { continuation.resume() }
    }
}
