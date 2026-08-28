import Foundation
import XCTest
@testable import BoneAgentKit

final class InferenceTokenBudgetTests: XCTestCase {
    func testSharedLimitsDecodeFromExtraConfiguration() throws {
        let json = """
        {"tokenLimits":{"contextWindowTokens":200000,"maximumInputTokens":180000,"maximumOutputTokens":64000,"source":"official","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}}
        """
        let limits = BoneModelContextLimits.decodeFromExtraConfiguration(json)
        XCTAssertEqual(limits?.contextWindowTokens, 200_000)
        XCTAssertEqual(limits?.maximumInputTokens, 180_000)
        XCTAssertEqual(limits?.maximumOutputTokens, 64_000)
        XCTAssertEqual(limits?.source, .official)
        XCTAssertNil(BoneModelContextLimits.decodeFromExtraConfiguration("{}"))
        XCTAssertNil(BoneModelContextLimits.decodeFromExtraConfiguration(
            "{\"tokenLimits\":{\"contextWindowTokens\":0}}"
        ))
    }

    func testLimitsCannotBypassValidationThroughCodable() throws {
        let invalid = Data("""
        {"contextWindowTokens":0,"source":"official","verifiedAt":"2026-08-28","documentationURL":"https://docs.example.com/model"}
        """.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(BoneModelContextLimits.self, from: invalid))
    }

    func testEstimatorConservativelyCountsTextAndMessageEnvelope() throws {
        XCTAssertEqual(BoneTokenEstimator.estimateText(""), 0)
        XCTAssertEqual(BoneTokenEstimator.estimateText("abcd"), 1)
        XCTAssertEqual(BoneTokenEstimator.estimateText("abcde"), 2)
        XCTAssertGreaterThanOrEqual(BoneTokenEstimator.estimateText("角色"), 2)
        XCTAssertGreaterThanOrEqual(BoneTokenEstimator.estimateText("😀"), 2)
        XCTAssertGreaterThan(
            BoneTokenEstimator.estimateMessage(.init(role: .user, content: "test")),
            1
        )
        let assistantTurn = try BoneInferenceAssistantTurn(content: [.text("非纯文本消息")])
        XCTAssertGreaterThan(
            BoneTokenEstimator.estimateMessage(.assistant(assistantTurn)),
            BoneTokenEstimator.messageEnvelopeTokens
        )
    }

    func testPlannerClampsOutputAndRemovesOldestHistory() throws {
        let limits = try BoneModelContextLimits(
            contextWindowTokens: 80,
            maximumInputTokens: 60,
            maximumOutputTokens: 20,
            source: .official,
            verifiedAt: "2026-08-28",
            documentationURL: XCTUnwrap(URL(string: "https://docs.example.com/model"))
        )
        let mandatory = [
            BoneInferenceMessage(role: .system, content: "system"),
            BoneInferenceMessage(role: .user, content: "current"),
        ]
        let history = [
            BoneInferenceMessage(role: .user, content: String(repeating: "旧", count: 30)),
            BoneInferenceMessage(role: .assistant, content: "newer"),
        ]
        let plan = try BoneContextWindowPlanner.plan(
            mandatoryMessages: mandatory,
            history: history,
            modelLimits: limits,
            configuredOutputTokens: 18,
            preferredOutputTokens: 16,
            protocolReserveTokens: 1,
            safetyMarginTokens: 1
        )

        XCTAssertEqual(plan.maximumOutputTokens, 16)
        XCTAssertEqual(plan.messages, [mandatory[0], history[1], mandatory[1]])
        XCTAssertEqual(plan.removedHistoryMessageCount, 1)
        XCTAssertLessThanOrEqual(plan.estimatedInputTokens, plan.availableInputTokens)
    }

    func testPlannerRejectsMandatoryInputWithoutLeakingContent() throws {
        let secret = "UNIQUE-TOKEN-BUDGET-SECRET"
        let limits = try BoneModelContextLimits(
            contextWindowTokens: 32,
            maximumInputTokens: 20,
            maximumOutputTokens: 8,
            source: .gateway,
            verifiedAt: "2026-08-28",
            documentationURL: XCTUnwrap(URL(string: "https://docs.example.com/gateway"))
        )

        XCTAssertThrowsError(try BoneContextWindowPlanner.plan(
            mandatoryMessages: [.init(role: .user, content: String(repeating: secret, count: 10))],
            history: [],
            modelLimits: limits,
            configuredOutputTokens: nil,
            preferredOutputTokens: 8,
            protocolReserveTokens: 1,
            safetyMarginTokens: 1
        )) { error in
            guard case let BoneContextWindowError.inputTokensExceeded(estimated, limit) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertGreaterThan(estimated, limit)
            XCTAssertFalse(String(describing: error).contains(secret))
        }
    }
}
