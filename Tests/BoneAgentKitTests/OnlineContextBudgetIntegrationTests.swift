import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class OnlineContextBudgetIntegrationTests: XCTestCase {
    func testThreeOnlineProtocolsUseExplicitModelBudgetAndTrimBeforeSending() async throws {
        let limits = try BoneModelContextLimits(contextWindowTokens: 512, maximumInputTokens: nil,
            maximumOutputTokens: 64, source: .official, verifiedAt: "2026-10-05", documentationURL: XCTUnwrap(URL(string: "https://example.com/model")))
        let url = try XCTUnwrap(URL(string: "https://synthetic.invalid"))
        for kind in [BoneInferenceProviderKind.openAI, .anthropic, .google] {
            let transport = ContextTransport(kind: kind)
            let config = BoneInferenceProviderConfiguration(kind: kind, apiKey: "synthetic", baseURL: url, authenticationMode: kind == .google ? .googleAPIKey : (kind == .anthropic ? .anthropicDual : .bearer))
            let engine: any BoneInferenceEngine
            switch kind {
            case .openAI: engine = BoneOpenAIInferenceEngine(configuration: config, transport: transport, modelContextLimits: ["model": limits])
            case .anthropic: engine = BoneAnthropicInferenceEngine(configuration: config, transport: transport, modelContextLimits: ["model": limits])
            default: engine = BoneGeminiInferenceEngine(configuration: config, transport: transport, modelContextLimits: ["model": limits])
            }
            let provider = try XCTUnwrap(engine as? any BoneInferenceContextBudgetProviding)
            XCTAssertEqual(try provider.contextBudget(for: "model")?.source, .model)
            XCTAssertNil(try provider.contextBudget(for: "unknown"))
            let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
                configuration: try .init(maximumSteps: 1, contextManagement: .init(protocolReserveTokens: 0, safetyMarginTokens: 0)))
            _ = try await agent.run(modelID: "model", messages: [
                .init(role: .system, content: "rules"), .init(role: .user, content: "old"),
                .init(role: .assistant, content: String(repeating: "removed-history", count: 200)), .init(role: .user, content: "current")])
            let bodies = await transport.bodies
            XCTAssertEqual(bodies.count, 1)
            let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
            XCTAssertFalse(body.contains("removed-history"))
            XCTAssertTrue(body.contains("current"))
        }
    }

    func testRollingSummaryInsertionKeepsGeminiSignatureIndicesValid() async throws {
        let turn = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "a", toolID: "tool", arguments: Data("{}".utf8)))])
        let result = try BoneInferenceMessage.toolResult(.init(callID: "a", toolID: "tool", content: .text("done"), isError: false, ordinal: 0))
        let history: [BoneInferenceMessage] = [.init(role: .user, content: String(repeating: "old detail ", count: 1200)),
            .init(role: .assistant, content: "prior"), .init(role: .user, content: "latest"), .assistant(turn), result]
        let previousSummary = "prior summary"
        let sentBefore = [try BoneContextSummaryCodec.message(previousSummary)] + history
        let parts: [[String: Any]] = [["functionCall": ["id": "a", "name": "tool", "args": [:]], "thoughtSignature": "opaque-signature"]]
        let continuation = try BoneGeminiContinuation.accumulating(
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: BoneGeminiContinuation.make(parts: parts)),
            after: .init(modelID: "model", messages: Array(sentBefore.dropLast(2)))
        ).continuationForTest
        let engine = BoneGeminiInferenceEngine(configuration: .init(kind: .google, apiKey: "synthetic", baseURL: URL(string: "https://synthetic.invalid")!), transport: ContextTransport(kind: .google))
        let summarizer = BoneScriptedInferenceEngine(script: [.init(text: "new summary")])
        let binding = try BoneInferenceEngineContextSummarizer(engine: summarizer, modelID: "summary", budget: .init(contextWindowTokens: 16384, source: .host))
        let budget = try BoneContextWindowBudget(contextWindowTokens: 2048, maximumOutputTokens: 64, source: .host)
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: binding,
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 64)
        var state = BoneContextSession()
        state.summary = previousSummary
        let prepared = try await state.prepare(request: .init(modelID: "model", messages: history, providerContinuation: continuation),
            engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertTrue(prepared.receipt?.usedModelSummary == true)
        let replay = try BoneGeminiContinuation.partsByMessage(from: prepared.request.providerContinuation, messages: prepared.request.messages)
        XCTAssertEqual(replay[2]?.first?["thoughtSignature"] as? String, "opaque-signature")
        let next = try await state.prepare(request: .init(modelID: "model", messages: prepared.history, providerContinuation: prepared.request.providerContinuation),
            engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertNil(next.receipt)
        XCTAssertNoThrow(try BoneGeminiContinuation.partsByMessage(from: next.request.providerContinuation, messages: next.request.messages))
    }

    func testCurrentTurnExchangeCompactionRebindsGeminiSignature() async throws {
        let first = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "a", toolID: "tool", arguments: Data("{}".utf8)))])
        let second = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "b", toolID: "tool", arguments: Data("{}".utf8)))])
        let text = String(repeating: "data ", count: 300)
        let user = BoneInferenceMessage(role: .user, content: "Current request")
        let initial = BoneInferenceRequest(modelID: "model", messages: [user])
        let signatureA = try BoneGeminiContinuation.make(parts: [["functionCall": ["name": "tool", "args": [:]], "thoughtSignature": "a-signature"]])
        let a = try BoneGeminiContinuation.accumulating(.assistantTurn(turn: first, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: signatureA), after: initial)
        let firstResult = try BoneInferenceMessage.toolResult(.init(callID: "a", toolID: "tool", content: .text(text), isError: false, ordinal: 0))
        let next = BoneInferenceRequest(modelID: "model", messages: [user, .assistant(first), firstResult], providerContinuation: a.continuationForTest)
        let signatureB = try BoneGeminiContinuation.make(parts: [["functionCall": ["name": "tool", "args": [:]], "thoughtSignature": "b-signature"]])
        let b = try BoneGeminiContinuation.accumulating(.assistantTurn(turn: second, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: signatureB), after: next)
        let result = try BoneInferenceMessage.toolResult(.init(callID: "b", toolID: "tool", content: .text(text), isError: false, ordinal: 0))
        let engine = BoneGeminiInferenceEngine(configuration: .init(kind: .google, apiKey: "synthetic", baseURL: URL(string: "https://synthetic.invalid")!), transport: ContextTransport(kind: .google))
        let budget = try BoneContextWindowBudget(contextWindowTokens: 1024, maximumOutputTokens: 64, source: .host)
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, protocolReserveTokens: 0, safetyMarginTokens: 0, minimumRecentToolExchangeCount: 1)
        var state = BoneContextSession()
        let prepared = try await state.prepare(request: .init(modelID: "model", messages: next.messages + [.assistant(second), result], providerContinuation: b.continuationForTest), engine: engine, policy: policy, meter: nil, clock: { 0 })
        XCTAssertEqual(prepared.receipt?.removedToolExchangeCount, 1)
        let parts = try BoneGeminiContinuation.partsByMessage(from: prepared.request.providerContinuation, messages: prepared.request.messages)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[1]?.first?["thoughtSignature"] as? String, "b-signature")
    }

    func testGeminiRebindsExactKeptTurnAndRejectsChangedOrDuplicateTurns() throws {
        let turn = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "a", toolID: "tool", arguments: Data("{}".utf8)))])
        let original: [BoneInferenceMessage] = [.init(role: .user, content: "old"), .init(role: .assistant, content: "prior"), .init(role: .user, content: "new"), .assistant(turn)]
        let parts: [[String: Any]] = [["functionCall": ["id": "a", "name": "tool", "args": [:]], "thoughtSignature": "private-signature"]]
        let continuation = try XCTUnwrap(BoneGeminiContinuation.accumulating(
            .assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: BoneGeminiContinuation.make(parts: parts)),
            after: .init(modelID: "model", messages: Array(original.dropLast()))
        ).continuationForTest)
        let compacted = [BoneInferenceMessage(role: .user, content: "historical summary"), original[2], original[3]]
        let remapped = try BoneGeminiContinuation.rebinding(continuation, from: original, to: compacted)
        let replay = try BoneGeminiContinuation.partsByMessage(from: remapped, messages: compacted)
        XCTAssertEqual(replay[2]?.first?["thoughtSignature"] as? String, "private-signature")
        XCTAssertThrowsError(try BoneGeminiContinuation.rebinding(continuation, from: original, to: compacted + [original[3]]))
        let changed = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "a", toolID: "tool", arguments: Data(#"{"modified":true}"#.utf8)))])
        XCTAssertThrowsError(try BoneGeminiContinuation.rebinding(continuation, from: original, to: [.assistant(changed)]))
        XCTAssertNil(try BoneGeminiContinuation.rebinding(continuation, from: original, to: [original[2]]))
    }
}
private extension BoneInferenceResponse {
    var continuationForTest: BoneInferenceProviderContinuation? {
        if case let .assistantTurn(_, _, _, _, value) = self { return value }
        return nil
    }
}
private actor ContextTransport: BoneInferenceHTTPTransport {
    let kind: BoneInferenceProviderKind
    var bodies: [Data] = []
    init(kind: BoneInferenceProviderKind) { self.kind = kind }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        let body: String
        switch kind {
        case .openAI: body = #"{"choices":[{"message":{"role":"assistant","content":"done"},"finish_reason":"stop"}]}"#
        case .anthropic: body = #"{"content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}"#
        default: body = #"{"candidates":[{"content":{"parts":[{"text":"done"}]},"finishReason":"STOP"}]}"#
        }
        return .init(statusCode: 200, data: Data(body.utf8), headers: [:])
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}
