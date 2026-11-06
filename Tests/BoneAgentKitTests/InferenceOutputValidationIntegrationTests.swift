import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class InferenceOutputValidationIntegrationTests: XCTestCase {
    func testTextNormalizationAndAcceptedValueAreChosenByCaller() async throws {
        let input = "  Mixed Case\n"
        let unchanged = try await BoneInferenceValidatedOutputProcessor<String, String, Void>()
            .process(input) { .accepted($0) }
        guard case .accepted(let raw) = unchanged.validation else { return XCTFail("Expected original text") }
        XCTAssertEqual(raw, input)

        let trace = OutputValidationTestTrace()
        let normalized = try await BoneInferenceValidatedOutputProcessor<String, Label, String>().process(
            input, policy: .init(maximumCorrectionAttempts: 1),
            validate: { candidate in
                await trace.append("validate:\(candidate)")
                guard candidate == candidate.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    return .rejected(try .init(issue: .contractMismatch, allowsCorrection: true, feedback: "trim"))
                }
                return .accepted(Label(value: candidate.lowercased()))
            },
            correct: { candidate, rejection, attempt in
                XCTAssertEqual(rejection.feedback, "trim")
                XCTAssertEqual(attempt, 1)
                await trace.append("normalize")
                return candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
        guard case .accepted(let label) = normalized.validation else { return XCTFail("Expected normalized label") }
        XCTAssertEqual(label, Label(value: "mixed case"))
        assertOutputReceipt(normalized.receipt, validations: 2, corrections: 1, outcome: .accepted)
        let events = await trace.events()
        XCTAssertEqual(events, ["validate:\(input)", "normalize", "validate:Mixed Case"])
    }

    func testStructuredJSONAndCustomRequiredItemUseExactlyOneScriptedCorrection() async throws {
        let samples: [(String, BoneInferenceOutputIssue)] = [
            ("{broken", .invalidFormat),
            (#"{}"#, .missingRequiredOutput),
            (#"{"items":[]}"#, .missingRequiredOutput),
            (#"{"items":[{"id":""}]}"#, .contractMismatch),
            (#"{"items":[{"id":"other"}]}"#, .missingRequiredOutput),
        ]
        let fixed = try Self.completeResponse(#"{"items":[{"id":"required"}]}"#)
        for (json, issue) in samples {
            let initial = Self.structured(json)
            let engine = BoneScriptedInferenceEngine(script: [fixed])
            let trace = OutputValidationTestTrace()
            let result = try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
                .process(initial, policy: .init(maximumCorrectionAttempts: 1),
                    validate: { response in
                        await trace.append("validate")
                        return try Self.validate(response, requiredIDs: ["required"])
                    },
                    correct: { candidate, rejection, attempt in
                        XCTAssertEqual(candidate, initial)
                        XCTAssertEqual(rejection.issue, issue)
                        XCTAssertEqual(attempt, 1)
                        let feedback = try XCTUnwrap(rejection.feedback)
                        await trace.append("infer")
                        return try await engine.infer(request: Self.request(feedback: feedback))
                    })
            guard case .accepted(let ids) = result.validation else { return XCTFail("Expected corrected JSON") }
            XCTAssertEqual(ids, ["required"])
            assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .accepted)
            let requests = await engine.receivedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(requests.first?.modelID, "synthetic-output-validation")
            XCTAssertEqual(requests.first?.availableTools, [])
            XCTAssertTrue(requests.first?.messages.first?.content?.hasPrefix("Repair JSON: ") == true)
            let events = await trace.events()
            XCTAssertEqual(events, ["validate", "infer", "validate"])
        }
    }

    func testValidEmptyArrayDependsOnCallerRule() async throws {
        let initial = Self.structured(#"{"items":[]}"#)
        let processor = BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
        let accepted = try await processor.process(initial) { try Self.validate($0) }
        guard case .accepted(let ids) = accepted.validation else { return XCTFail("Empty is valid for this caller") }
        XCTAssertEqual(ids, [])
        assertOutputReceipt(accepted.receipt, validations: 1, corrections: 0, outcome: .accepted)

        let rejected = try await processor.process(initial) { try Self.validate($0, allowsEmpty: false) }
        guard case .rejected(let report) = rejected.validation else { return XCTFail("This caller requires an item") }
        XCTAssertEqual(report.feedback, "At least one item is required")
        assertOutputReceipt(rejected.receipt, validations: 1, corrections: 0, outcome: .rejected(.missingRequiredOutput))
    }

    func testToolIncompleteRefusedAndAmbiguousResponseShapesNeverTriggerInference() async throws {
        let data = Data(#"{"items":[]}"#.utf8)
        let call = BoneInferenceToolCall(id: "call-1", toolID: "synthetic-tool", arguments: Data("{}".utf8))
        let shapes: [BoneInferenceResponse] = [
            .toolCall(call),
            .finish(.init(text: String(decoding: data, as: UTF8.self))),
            try Self.turn([.structured(data)], reason: .length),
            try Self.turn([.structured(data)], reason: .contentFilter),
            try Self.turn([.structured(data)], refusal: .policy),
            try Self.turn([.structured(data), .toolCall(call)], reason: .toolCalls),
            try Self.turn([.structured(data), .toolCall(call)]),
            try Self.turn([.structured(data), .structured(data)]),
            try Self.turn([.structured(data), .text("extra output")]),
        ]
        for response in shapes {
            let engine = BoneScriptedInferenceEngine(script: [Self.structured(#"{"items":[]}"#)])
            let result = try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
                .process(response, policy: .init(maximumCorrectionAttempts: 2),
                    validate: { try Self.validate($0) },
                    correct: { _, _, _ in try await engine.infer(request: Self.request(feedback: "unexpected")) })
            guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected shape rejection") }
            XCTAssertFalse(rejection.allowsCorrection)
            assertOutputReceipt(result.receipt, validations: 1, corrections: 0, outcome: .rejected(.contractMismatch))
            let requests = await engine.receivedRequests()
            XCTAssertEqual(requests.count, 0)
        }
    }

    func testCorrectedResponseMustStillHaveCompleteShape() async throws {
        let truncated = try Self.turn([.structured(Data(#"{"items":[]}"#.utf8))], reason: .length)
        let engine = BoneScriptedInferenceEngine(script: [truncated])
        let result = try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
            .process(Self.structured("{broken"), policy: .init(maximumCorrectionAttempts: 3),
                validate: { try Self.validate($0) },
                correct: { _, _, _ in try await engine.infer(request: Self.request(feedback: "invalid JSON")) })
        guard case .rejected(let rejection) = result.validation else { return XCTFail("Expected incomplete shape rejection") }
        XCTAssertFalse(rejection.allowsCorrection)
        assertOutputReceipt(result.receipt, validations: 2, corrections: 1, outcome: .rejected(.contractMismatch))
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func testExhaustedRunBudgetBlocksCorrectionBeforeEngineReceivesRequest() async throws {
        let meter = try Self.meter()
        try await meter.reserveInference(inputBytes: 0, estimatedCostMicrounits: 0, nowUptime: 0)
        let engine = BoneScriptedInferenceEngine(script: [Self.structured(#"{"items":[]}"#)])
        let trace = OutputValidationTestTrace()
        do {
            _ = try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
                .process(Self.structured("{broken"), policy: .init(maximumCorrectionAttempts: 2),
                    validate: { response in
                        await trace.append("validate")
                        return try Self.validate(response)
                    },
                    correct: { _, _, _ in
                        await trace.append("reserve")
                        try await meter.reserveInference(inputBytes: 1, estimatedCostMicrounits: 1, nowUptime: 0)
                        return try await engine.infer(request: Self.request(feedback: "invalid JSON"))
                    })
            XCTFail("Expected budget error, no receipt")
        } catch {
            XCTAssertEqual(error as? BoneRunBudgetError, .inferenceCallLimitReached(limit: 1))
        }
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
        let events = await trace.events()
        XCTAssertEqual(events, ["validate", "reserve"])
    }

    func testFailedInferenceAfterReservationDoesNotRefundBudgetOrRetry() async throws {
        let meter = try Self.meter()
        let engine = BoneScriptedInferenceEngine(script: [])
        let trace = OutputValidationTestTrace()
        do {
            _ = try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
                .process(Self.structured("{broken"), policy: .init(maximumCorrectionAttempts: 3),
                    validate: { response in
                        await trace.append("validate")
                        return try Self.validate(response)
                    },
                    correct: { _, _, _ in
                        await trace.append("reserve")
                        try await meter.reserveInference(inputBytes: 1, estimatedCostMicrounits: 1, nowUptime: 0)
                        await trace.append("infer")
                        return try await engine.infer(request: Self.request(feedback: "invalid JSON"))
                    })
            XCTFail("Expected original engine failure, no receipt")
        } catch {
            XCTAssertEqual(error as? BoneScriptedInferenceEngineError, .scriptExhausted)
        }
        do {
            try await meter.reserveInference(inputBytes: 0, estimatedCostMicrounits: 0, nowUptime: 0)
            XCTFail("Accepted reservation must remain consumed after failure")
        } catch {
            XCTAssertEqual(error as? BoneRunBudgetError, .inferenceCallLimitReached(limit: 1))
        }
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests, [Self.request(feedback: "invalid JSON")])
        let events = await trace.events()
        XCTAssertEqual(events, ["validate", "reserve", "infer"])
    }

    func testReceivedButRejectedCorrectionStillConsumesOutputBudget() async throws {
        let rejected = try Self.turn([.structured(Data(#"{"items":[]}"#.utf8))], reason: .length)
        let accepted = try Self.completeResponse(#"{"items":[{"id":"ok"}]}"#)
        let outputLimit = try JSONEncoder().encode(rejected).count + JSONEncoder().encode(accepted).count - 1
        let meter = BoneRunBudgetMeter(budget: try .init(maximumInferenceCalls: 2, maximumToolCalls: 1,
            maximumInputBytes: 1_024, maximumOutputBytes: outputLimit, maximumTurns: 2,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: 10), startedAtUptime: 0)
        let engine = BoneScriptedInferenceEngine(script: [rejected, accepted])
        let processor = BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
        let correction: BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>.Correction = { _, _, _ in
            try await Self.budgetedResponse(engine: engine, meter: meter) {
                try await meter.reserveInference(inputBytes: 1, estimatedCostMicrounits: 1, nowUptime: 0)
            }
        }
        let first = try await processor.process(Self.structured("{broken"),
            policy: .init(maximumCorrectionAttempts: 1),
            validate: { try Self.validate($0) }, correct: correction)
        assertOutputReceipt(first.receipt, validations: 2, corrections: 1, outcome: .rejected(.contractMismatch))
        do {
            _ = try await processor.process(Self.structured("{broken"),
                policy: .init(maximumCorrectionAttempts: 1),
                validate: { try Self.validate($0) }, correct: correction)
            XCTFail("Rejected response bytes must count toward cumulative output")
        } catch {
            XCTAssertEqual(error as? BoneRunBudgetError, .outputByteLimitReached(limit: outputLimit))
        }
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testCancellationAfterBudgetReservationDoesNotStartInferenceOrRefund() async throws {
        let meter = try Self.meter()
        let engine = BoneScriptedInferenceEngine(script: [Self.structured(#"{"items":[]}"#)])
        let task = Task {
            try await BoneInferenceValidatedOutputProcessor<BoneInferenceResponse, [String], String>()
                .process(Self.structured("{broken"), policy: .init(maximumCorrectionAttempts: 1),
                    validate: { try Self.validate($0) },
                    correct: { _, _, _ in
                        try await Self.budgetedResponse(engine: engine, meter: meter) {
                            try await meter.reserveInference(inputBytes: 1, estimatedCostMicrounits: 1, nowUptime: 0)
                            // 模拟预留成功、恢复执行时已收到取消；没有时间竞争或 sleep。
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
        }
        do { _ = try await task.value; XCTFail("Cancelled reservation must not dispatch") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 0)
        do {
            try await meter.reserveInference(inputBytes: 0, estimatedCostMicrounits: 0, nowUptime: 0)
            XCTFail("Reserved attempts are not refunded by cancellation")
        } catch {
            XCTAssertEqual(error as? BoneRunBudgetError, .inferenceCallLimitReached(limit: 1))
        }
    }

    // 调用方组合与文档相同的顺序；注入准入闭包以确定性验证 await 后的取消边界。
    private static func budgetedResponse(
        engine: BoneScriptedInferenceEngine,
        meter: BoneRunBudgetMeter,
        reserve: @Sendable () async throws -> Void
    ) async throws -> BoneInferenceResponse {
        try Task.checkCancellation()
        try await reserve()
        try Task.checkCancellation()
        let response = try await engine.infer(request: Self.request(feedback: "invalid JSON"))
        try await meter.commitInference(outputBytes: JSONEncoder().encode(response).count)
        try Task.checkCancellation()
        return response
    }

    private struct Label: Equatable, Sendable { let value: String }
    private struct Document: Decodable, Sendable {
        struct Item: Decodable, Sendable { let id: String }
        let items: [Item]
    }

    // This is an explicit caller contract: only one complete structured result is eligible.
    // Only known decoding/contract problems are repairable; operational errors are never caught here.
    private static func validate(
        _ response: BoneInferenceResponse,
        requiredIDs: Set<String> = [],
        allowsEmpty: Bool = true
    ) throws -> BoneInferenceOutputValidation<[String], String> {
        let data: Data
        switch response {
        case .structured(let result):
            data = result.data
        case .assistantTurn(let turn, let reason, _, let refusal, _):
            guard reason == .stop, refusal == nil, turn.content.count == 1,
                  case .structured(let payload) = turn.content[0] else {
                return .rejected(try .init(issue: .contractMismatch))
            }
            data = payload
        case .finish, .toolCall:
            return .rejected(try .init(issue: .contractMismatch))
        }
        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch DecodingError.keyNotFound {
            return .rejected(try .init(issue: .missingRequiredOutput, allowsCorrection: true,
                feedback: "Required JSON field is missing"))
        } catch is DecodingError {
            return .rejected(try .init(issue: .invalidFormat, allowsCorrection: true, feedback: "Invalid JSON document"))
        }
        let ids = document.items.map(\.id)
        guard ids.allSatisfy({ !$0.isEmpty }) else {
            return .rejected(try .init(issue: .contractMismatch, allowsCorrection: true, feedback: "Item IDs must be nonempty"))
        }
        guard allowsEmpty || !ids.isEmpty else {
            return .rejected(try .init(issue: .missingRequiredOutput, allowsCorrection: true,
                feedback: "At least one item is required"))
        }
        guard requiredIDs.isSubset(of: Set(ids)) else {
            return .rejected(try .init(issue: .missingRequiredOutput, allowsCorrection: true,
                feedback: "Required item is missing"))
        }
        return .accepted(ids)
    }

    private static func structured(_ json: String) -> BoneInferenceResponse {
        .structured(.init(data: Data(json.utf8)))
    }

    private static func completeResponse(_ json: String) throws -> BoneInferenceResponse {
        try turn([.structured(Data(json.utf8))])
    }

    private static func turn(
        _ content: [BoneInferenceAssistantContent],
        reason: BoneInferenceFinishReason = .stop,
        refusal: BoneInferenceRefusal? = nil
    ) throws -> BoneInferenceResponse {
        .assistantTurn(turn: try .init(content: content), finishReason: reason,
            usage: nil, refusal: refusal, providerContinuation: nil)
    }

    private static func request(feedback: String) -> BoneInferenceRequest {
        .init(modelID: "synthetic-output-validation", messages: [.init(role: .user, content: "Repair JSON: \(feedback)")])
    }

    private static func meter() throws -> BoneRunBudgetMeter {
        BoneRunBudgetMeter(budget: try .init(maximumInferenceCalls: 1, maximumToolCalls: 1,
            maximumInputBytes: 1_024, maximumOutputBytes: 1_024, maximumTurns: 1,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: 10), startedAtUptime: 0)
    }
}
