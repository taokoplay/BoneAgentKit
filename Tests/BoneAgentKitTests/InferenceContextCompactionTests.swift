import Foundation
import XCTest
@testable import BoneAgentKit

final class InferenceContextCompactionTests: XCTestCase {
    func testToolCallAndResultStayTogetherWhenOlderTurnIsRemoved() throws {
        let call = BoneInferenceToolCall(id: "call-1", toolID: "read", arguments: Data(#"{"path":"a"}"#.utf8))
        let result = try BoneInferenceToolResult(
            callID: "call-1", toolID: "read", content: .text("old result"), isError: false, ordinal: 0
        )
        let messages: [BoneInferenceMessage] = [
            .init(role: .system, content: "instructions"),
            .init(role: .user, content: "old question"),
            .assistant(try .init(content: [.toolCall(call)])),
            .toolResult(result),
            .init(role: .user, content: "current question"),
        ]
        let budget = try BoneContextWindowBudget(
            contextWindowTokens: 80, maximumInputTokens: 45, maximumOutputTokens: 10, source: .runtime
        )
        let candidate = try BoneContextCompactor.compact(
            messages: messages,
            budget: budget,
            configuredOutputTokens: 10,
            preferredOutputTokens: 10,
            minimumRecentTurnCount: 1,
            protocolReserveTokens: 0,
            safetyMarginTokens: 0
        )
        XCTAssertEqual(candidate.messages.first?.role, .system)
        XCTAssertEqual(candidate.messages.last?.content, "current question")
        XCTAssertFalse(candidate.messages.contains { $0.content == "old question" })
        XCTAssertEqual(candidate.receipt.removedTurnCount, 1)
    }

    func testToolResultClampPreservesIdentityAndChangesJSONToText() throws {
        let result = try BoneInferenceToolResult(
            callID: "call-1", toolID: "read", content: .json(Data(#"{"payload":"01234567890123456789"}"#.utf8)), isError: false, ordinal: 0
        )
        let messages: [BoneInferenceMessage] = [
            .init(role: .user, content: "question"),
            .assistant(try .init(content: [.toolCall(.init(id: "call-1", toolID: "read", arguments: Data(#"{}"#.utf8)))])),
            .toolResult(result),
        ]
        let budget = try BoneContextWindowBudget(contextWindowTokens: 1_024, maximumOutputTokens: 64, source: .runtime)
        let candidate = try BoneContextCompactor.compact(
            messages: messages,
            budget: budget,
            preferredOutputTokens: 64,
            minimumRecentTurnCount: 1,
            sourceRevision: 4,
            protocolReserveTokens: 0,
            safetyMarginTokens: 0,
            toolResultPolicy: { $0 == "read" ? .clamp(maximumBytes: 32) : .retain }
        )
        let batch = try XCTUnwrap(candidate.messages.last?.requiredToolResults())
        XCTAssertEqual(batch.results.first?.callID, "call-1")
        XCTAssertEqual(batch.results.first?.toolID, "read")
        XCTAssertEqual(batch.results.first?.ordinal, 0)
        if case let .text(value) = try XCTUnwrap(batch.results.first?.content) {
            XCTAssertTrue(value.contains("context-compacted"))
        } else {
            XCTFail("clamped JSON must become a valid bounded text payload")
        }
        XCTAssertEqual(candidate.receipt.sourceRevision, 4)
        XCTAssertEqual(candidate.receipt.resultingRevision, 5)
        XCTAssertEqual(candidate.receipt.clampedToolResultCount, 1)
    }

    func testUnicodeClampHonorsByteLimitAndRetainsFlags() throws {
        let call = BoneInferenceToolCall(id: "c", toolID: "read", arguments: Data("{}".utf8))
        for limit in [19, 32, 65, 128] {
            let message = BoneInferenceMessage.toolResult(try .init(callID: "c", toolID: "read",
                content: .text(String(repeating: "角色👨‍👩‍👧‍👧", count: 100)), isError: true, ordinal: 0))
            let result = try BoneContextCompactor.compact(messages: [.init(role: .user, content: "now"), .assistant(.init(content: [.toolCall(call)])), message],
                budget: .init(contextWindowTokens: 4096, source: .runtime), preferredOutputTokens: 64,
                toolResultPolicy: { _ in .clamp(maximumBytes: limit) })
            let output = try XCTUnwrap(result.messages.last?.requiredToolResults().results.first)
            XCTAssertLessThanOrEqual(output.content.byteCount, limit)
            XCTAssertTrue(output.isError)
            if case let .text(text) = output.content { XCTAssertFalse(text.contains("�")); XCTAssertTrue(text.contains("context-compacted")) }
        }
    }

    func testMalformedToolHistoryAndMidConversationSystemCannotBeSilentlyDropped() throws {
        let call = BoneInferenceToolCall(id: "c", toolID: "read", arguments: Data("{}".utf8))
        let turn = try BoneInferenceMessage.assistant(.init(content: [.toolCall(call)]))
        let wrong = try BoneInferenceMessage.toolResult(.init(callID: "c", toolID: "wrong", content: .text("result"), isError: false, ordinal: 0))
        for messages in [[turn, wrong, .init(role: .user, content: "new")], [turn, .init(role: .user, content: "new")],
                         [.init(role: .user, content: "old"), .init(role: .system, content: "late"), .init(role: .user, content: "new")]] {
            XCTAssertThrowsError(try BoneContextCompactor.compact(messages: messages, budget: .init(contextWindowTokens: 4096, source: .host), preferredOutputTokens: 64)) {
                XCTAssertEqual($0 as? BoneContextCompactionError, .invalidHistory)
            }
        }
    }

    func testRevisionCannotWrap() throws {
        XCTAssertThrowsError(try BoneContextCompactor.compact(messages: [.init(role: .user, content: String(repeating: "x", count: 3000)), .init(role: .user, content: "now")],
            budget: .init(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host), sourceRevision: .max,
            protocolReserveTokens: 0, safetyMarginTokens: 0)) {
            XCTAssertEqual($0 as? BoneContextCompactionError, .revisionOverflow)
        }
    }

    func testNoProgressIsReportedWhenHistoryAlreadyFits() throws {
        let messages = [BoneInferenceMessage(role: .user, content: "question")]
        let budget = try BoneContextWindowBudget(contextWindowTokens: 4_096, source: .runtime)
        XCTAssertThrowsError(try BoneContextCompactor.compact(
            messages: messages,
            budget: budget,
            preferredOutputTokens: 64,
            protocolReserveTokens: 0,
            safetyMarginTokens: 0
        )) { error in
            XCTAssertEqual(error as? BoneContextCompactionError, .noProgress)
        }
    }
}
