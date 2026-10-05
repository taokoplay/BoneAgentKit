import Foundation
import XCTest
@testable import BoneAgentKit

final class InferenceContextBudgetTests: XCTestCase {
    func testVerifiedModelLimitsConvertToSharedBudget() throws {
        let limits = try BoneModelContextLimits(
            contextWindowTokens: 4_096,
            maximumInputTokens: 3_000,
            maximumOutputTokens: 1_024,
            source: .official,
            verifiedAt: "2026-10-04",
            documentationURL: XCTUnwrap(URL(string: "https://example.com/model"))
        )
        let budget = limits.contextWindowBudget
        XCTAssertEqual(budget.contextWindowTokens, 4_096)
        XCTAssertEqual(budget.maximumInputTokens, 3_000)
        XCTAssertEqual(budget.maximumOutputTokens, 1_024)
        XCTAssertEqual(budget.source, .model)
    }

    func testRuntimeBudgetDoesNotRequireProviderDocumentation() throws {
        let budget = try BoneContextWindowBudget(
            contextWindowTokens: 2_048,
            maximumOutputTokens: 512,
            source: .runtime
        )
        let capacity = try budget.availableInputTokens(
            configuredOutputTokens: 256,
            preferredOutputTokens: nil,
            protocolReserveTokens: 0,
            safetyMarginTokens: 0
        )
        XCTAssertEqual(capacity.maximumOutputTokens, 256)
        XCTAssertEqual(capacity.availableInputTokens, 1_792)
        XCTAssertEqual(budget.source, .runtime)
    }

    func testDecodingCannotBypassValidationAndReservationsDoNotOverflow() throws {
        for json in [#"{"contextWindowTokens":0,"source":"runtime"}"#, #"{"contextWindowTokens":100,"maximumInputTokens":101,"source":"host"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(BoneContextWindowBudget.self, from: Data(json.utf8)))
        }
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, source: .runtime)
        XCTAssertThrowsError(try budget.availableInputTokens(configuredOutputTokens: Int.max, preferredOutputTokens: nil,
            protocolReserveTokens: Int.max, safetyMarginTokens: Int.max)) { error in
            guard case BoneContextWindowError.inputBudgetUnavailable = error else { return XCTFail("wrong error") }
        }
    }

    func testHostBudgetCannotEnlargeRuntimeAndOutputCannotExceedWindow() throws {
        XCTAssertThrowsError(try BoneContextWindowBudget(contextWindowTokens: 128, maximumOutputTokens: 129, source: .host))
        XCTAssertThrowsError(try JSONDecoder().decode(BoneContextWindowBudget.self, from: Data(#"{"contextWindowTokens":128,"maximumOutputTokens":129,"source":"runtime"}"#.utf8)))
        let host = try BoneContextWindowBudget(contextWindowTokens: 128, source: .host)
        let runtime = try BoneContextWindowBudget(contextWindowTokens: 4096, maximumOutputTokens: 1024, source: .runtime)
        let result = try host.constrained(by: runtime)
        XCTAssertEqual(result.contextWindowTokens, 128)
        XCTAssertEqual(result.maximumOutputTokens, 128)
    }

    func testPrivateHistoryReferenceRejectsPathsURLsAndInvalidDecodedRevisions() throws {
        for value in ["", "/private/path", "https://example.com/private", "secret token"] {
            XCTAssertThrowsError(try BoneContextHistoryReference(opaqueID: value, revision: 1, leaseGeneration: 0))
        }
        let valid = try BoneContextHistoryReference(opaqueID: "context-opaque-1", revision: 3, leaseGeneration: 7)
        XCTAssertEqual(try JSONDecoder().decode(BoneContextHistoryReference.self, from: JSONEncoder().encode(valid)), valid)
        XCTAssertThrowsError(try JSONDecoder().decode(BoneContextHistoryReference.self,
            from: Data(#"{"opaqueID":"context-1","revision":0,"leaseGeneration":0}"#.utf8)))
    }

    func testPlannerAcceptsRuntimeBudget() throws {
        let budget = try BoneContextWindowBudget(
            contextWindowTokens: 128,
            maximumInputTokens: 96,
            maximumOutputTokens: 32,
            source: .runtime
        )
        let plan = try BoneContextWindowPlanner.plan(
            mandatoryMessages: [.init(role: .system, content: "system")],
            history: [.init(role: .user, content: "old")],
            budget: budget,
            configuredOutputTokens: 16,
            preferredOutputTokens: nil,
            protocolReserveTokens: 1,
            safetyMarginTokens: 1
        )
        XCTAssertEqual(plan.maximumOutputTokens, 16)
        XCTAssertEqual(plan.messages.count, 2)
    }
}
