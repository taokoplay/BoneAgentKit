import Foundation
import XCTest
@testable import BoneAgentKit

final class GeminiMultiTurnRegressionTests: XCTestCase {
    func testAgentCompletesTwoToolTurnsAndReplaysEverySignature() async throws {
        for streaming in [false, true] {
            for nativeIDs in [false, true] {
                for signatures in [false, true] {
                    let transport = GeminiHistoryTransport(nativeIDs: nativeIDs, signatures: signatures)
                    let engine = makeEngine(transport)
                    let agent = BoneAgent(inferenceEngine: engine,
                        toolRegistry: try .init(tools: [BoneAnyAgentTool(GeminiHistoryTool())]),
                        toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 3,
                            inferenceMode: streaming ? .bufferedStreaming(.init(totalTimeout: 30)) : .nonStreaming))
                    do {
                        let result = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "test")])
                        XCTAssertEqual(result.output, .text("done"))
                    } catch { XCTFail("stream=\(streaming) nativeIDs=\(nativeIDs) signatures=\(signatures): \(error)") }
                    let bodies = await transport.bodies
                    XCTAssertEqual(bodies.count, 3)
                    if let last = bodies.last, bodies.count == 3 {
                        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: last) as? [String: Any])
                        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
                        let modelParts = contents.filter { $0["role"] as? String == "model" }
                            .flatMap { $0["parts"] as? [[String: Any]] ?? [] }
                        XCTAssertEqual(modelParts.compactMap { $0["thoughtSignature"] as? String }, signatures ? ["signature-1", "signature-2"] : [])
                        let ids = contents.flatMap { $0["parts"] as? [[String: Any]] ?? [] }
                            .compactMap { ($0["functionResponse"] as? [String: Any])?["id"] as? String }
                        XCTAssertEqual(ids.count, 2)
                        XCTAssertEqual(Set(ids).count, 2)
                    }
                }
            }
        }
    }

    func testEventIDsMatchCompletedTurnAndAreUniqueAcrossRequests() async throws {
        let engine = makeEngine(GeminiHistoryTransport(nativeIDs: false, signatures: true))
        var previousID: String?
        for _ in 0..<2 {
            var startedIDs: [String] = []
            var finalIDs: [String] = []
            for try await event in engine.inferenceEvents(request: .init(modelID: "model",
                messages: [.init(role: .user, content: "test")], availableTools: [GeminiHistoryTool.definition]), options: .init()) {
                switch event {
                case let .toolCallStarted(id, _): startedIDs.append(id)
                case let .completed(result):
                    if case let .assistantTurn(turn, _, _, _, _) = result.response { finalIDs = turn.toolCalls.map(\.id) }
                default: break
                }
            }
            XCTAssertEqual(startedIDs.count, 1)
            XCTAssertEqual(startedIDs, finalIDs)
            if let previousID { XCTAssertNotEqual(startedIDs.first, previousID) }
            previousID = startedIDs.first
        }
    }

    func testMissingStreamingUsageStaysUnknownButMalformedUsageFails() throws {
        let withoutUsage = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"done"}]}}]}"#
        let response = try BoneGeminiToolStreamAggregator.aggregate(events: [.init(data: withoutUsage)], definitions: [])
        guard case let .assistantTurn(turn, reason, usage, _, _) = response else { return XCTFail("Expected turn") }
        XCTAssertEqual(turn.text, "done")
        XCTAssertEqual(reason, .stop)
        XCTAssertNil(usage)
        for suffix in [#""usageMetadata":{}"#, #""usageMetadata":{"promptTokenCount":1}"#, #""usageMetadata":"invalid""#, #""usageMetadata":[]"#] {
            let malformed = String(withoutUsage.dropLast()) + "," + suffix + "}"
            XCTAssertThrowsError(try BoneGeminiToolStreamAggregator.aggregate(events: [.init(data: malformed)], definitions: []))
        }
    }

    func testUnsignedLaterTurnDoesNotEraseEarlierSignature() async throws {
        let transport = GeminiHistoryTransport(nativeIDs: true, signatures: true, signatureTurns: [1])
        let agent = BoneAgent(inferenceEngine: makeEngine(transport),
            toolRegistry: try .init(tools: [BoneAnyAgentTool(GeminiHistoryTool())]),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 3))
        _ = try await agent.run(modelID: "model", messages: [.init(role: .user, content: "test")])
        let bodies = await transport.bodies
        let final = String(decoding: try XCTUnwrap(bodies.last), as: UTF8.self)
        XCTAssertTrue(final.contains("signature-1"))
        XCTAssertFalse(final.contains("signature-2"))
    }

    func testContinuationRejectsChangedOrReorderedHistoryBeforeSending() async throws {
        let transport = GeminiHistoryTransport(nativeIDs: true, signatures: true)
        let engine = makeEngine(transport)
        let user = BoneInferenceMessage(role: .user, content: "test")
        let first = try await engine.infer(request: .init(modelID: "model", messages: [user], availableTools: [GeminiHistoryTool.definition]))
        guard case let .assistantTurn(turn, _, _, _, continuation) = first else { return XCTFail("Expected tool turn") }
        let wrong = try BoneInferenceAssistantTurn(content: [.text("changed")])
        for messages in [[user, .assistant(wrong)], [.assistant(turn), user], [user]] {
            do {
                _ = try await engine.infer(request: .init(modelID: "model", messages: messages,
                    availableTools: [GeminiHistoryTool.definition], providerContinuation: continuation))
                XCTFail("Changed history must be rejected")
            } catch { XCTAssertEqual(error as? BoneInferenceError, .invalidProviderContinuation) }
        }
        let count = await transport.bodies.count
        XCTAssertEqual(count, 1)
    }

    func testLegacySingleTurnEnvelopeStillReplaysAndOversizedHistoryFailsClosed() throws {
        let call = BoneInferenceToolCall(id: "native", toolID: "echo", arguments: Data("{}".utf8))
        let turn = try BoneInferenceAssistantTurn(content: [.toolCall(call)])
        let parts: [[String: Any]] = [["functionCall": ["id": "native", "name": "echo", "args": [:]], "thoughtSignature": "signature"]]
        let legacy = try BoneGeminiContinuation.make(parts: parts)
        let contents = try BoneGeminiToolWire.contents([.assistant(turn)], definitions: [GeminiHistoryTool.definition], continuation: legacy)
        XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: contents), as: UTF8.self).contains("signature"))
        let oversized: [[String: Any]] = [["text": "ok", "thoughtSignature": String(repeating: "s", count: BoneInferenceProviderContinuation.maximumByteCount)]]
        XCTAssertThrowsError(try BoneGeminiContinuation.make(parts: oversized)) {
            XCTAssertEqual($0 as? BoneInferenceError, .providerContinuationTooLarge)
        }
    }

    func testSignedToolHistorySurvivesStopAndNextUserMessage() throws {
        let definition = GeminiHistoryTool.definition
        let call = BoneInferenceToolCall(id: "native", toolID: "echo", arguments: Data("{}".utf8))
        let turn = try BoneInferenceAssistantTurn(content: [.toolCall(call)])
        let user = BoneInferenceMessage(role: .user, content: "test")
        let parts: [[String: Any]] = [["functionCall": ["id": "native", "name": "echo", "args": [:]], "thoughtSignature": "old-signature"]]
        let first = try BoneGeminiContinuation.accumulating(.assistantTurn(turn: turn, finishReason: .toolCalls,
            usage: nil, refusal: nil, providerContinuation: BoneGeminiContinuation.make(parts: parts)),
            after: .init(modelID: "model", messages: [user]))
        guard case let .assistantTurn(_, _, _, _, firstContinuation) = first else { return XCTFail() }
        let finalTurn = try BoneInferenceAssistantTurn(content: [.text("done")])
        let stopped = try BoneGeminiContinuation.accumulating(.assistantTurn(turn: finalTurn, finishReason: .stop,
            usage: nil, refusal: nil, providerContinuation: nil),
            after: .init(modelID: "model", messages: [user, .assistant(turn)], providerContinuation: firstContinuation))
        guard case let .assistantTurn(_, _, _, _, stoppedContinuation) = stopped else { return XCTFail() }
        let contents = try BoneGeminiToolWire.contents([user, .assistant(turn), .assistant(finalTurn), .init(role: .user, content: "next")],
            definitions: [definition], continuation: stoppedContinuation)
        XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: contents), as: UTF8.self).contains("old-signature"))
    }

    func testSignatureOnlyPartsReplayWithoutChangingFormalBlocks() throws {
        for metadata: [String: Any] in [["text": "", "thoughtSignature": "secret"], ["thoughtSignature": "secret"]] {
            let response = try BoneGeminiToolWire.parseResponse(["candidates": [["finishReason": "STOP", "content": ["parts": [
                ["functionCall": ["name": "echo", "args": [:]]], metadata
            ]]]]], definitions: [GeminiHistoryTool.definition])
            guard case let .assistantTurn(turn, _, _, _, continuation) = response else { return XCTFail() }
            let contents = try BoneGeminiToolWire.contents([.assistant(turn)], definitions: [GeminiHistoryTool.definition], continuation: continuation)
            XCTAssertEqual(turn.toolCalls.count, 1)
            XCTAssertTrue(String(decoding: try JSONSerialization.data(withJSONObject: contents), as: UTF8.self).contains("secret"))
        }
    }

    func testThoughtFunctionCallIsRejectedByBothEventAndFinalParser() throws {
        let data = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"functionCall":{"name":"echo","args":{}}},{"functionCall":{"name":"echo","args":{}}}]}}]}"#
        var mapper = BoneGeminiNormalizedEventMapper(disclosure: .hidden, definitions: [GeminiHistoryTool.definition])
        XCTAssertThrowsError(try mapper.consume(.init(data: data)))
        XCTAssertThrowsError(try BoneGeminiToolStreamAggregator.aggregate(events: [.init(data: data)], definitions: [GeminiHistoryTool.definition]))
    }

    func testIndividuallyValidContinuationsCannotExceedCombinedLimit() throws {
        var messages = [BoneInferenceMessage(role: .user, content: "test")]
        var continuation: BoneInferenceProviderContinuation?
        for index in 0..<2 {
            let turn = try BoneInferenceAssistantTurn(content: [.toolCall(.init(id: "call-\(index)", toolID: "echo", arguments: Data("{}".utf8)))])
            let parts: [[String: Any]] = [["functionCall": ["id": "call-\(index)", "name": "echo", "args": [:]],
                "thoughtSignature": String(repeating: "s", count: 140_000)]]
            let response = BoneInferenceResponse.assistantTurn(turn: turn, finishReason: .toolCalls, usage: nil, refusal: nil,
                providerContinuation: try BoneGeminiContinuation.make(parts: parts))
            let request = BoneInferenceRequest(modelID: "model", messages: messages, providerContinuation: continuation)
            if index == 0 {
                guard case let .assistantTurn(_, _, _, _, next) = try BoneGeminiContinuation.accumulating(response, after: request) else { return XCTFail() }
                continuation = next
                messages.append(.assistant(turn))
            } else {
                XCTAssertThrowsError(try BoneGeminiContinuation.accumulating(response, after: request)) {
                    XCTAssertEqual($0 as? BoneInferenceError, .providerContinuationTooLarge)
                }
            }
        }
    }

    func testTextMergingCannotHideMixedFunctionCallParts() throws {
        let mixed = #"{"text":"suffix","functionCall":{"name":"echo","args":{}}}"#
        let together = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"prefix"},\#(mixed)]}}]}"#
        let first = #"{"candidates":[{"content":{"parts":[{"text":"prefix"}]}}]}"#
        let second = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[\#(mixed)]}}]}"#
        for events: [BoneInferenceEventStreamEvent] in [[.init(data: together)], [.init(data: first), .init(data: second)]] {
            XCTAssertThrowsError(try BoneGeminiToolStreamAggregator.aggregate(events: events, definitions: [GeminiHistoryTool.definition]))
            var mapper = BoneGeminiNormalizedEventMapper(disclosure: .hidden, definitions: [GeminiHistoryTool.definition])
            XCTAssertThrowsError(try events.forEach { _ = try mapper.consume($0) })
        }
    }

    func testNonStreamingMalformedUsageIsNotSilentlyDropped() throws {
        for raw: Any in ["invalid", [], [:], ["promptTokenCount": 1]] {
            let json: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "done"]]]]], "usageMetadata": raw]
            XCTAssertThrowsError(try BoneGeminiToolWire.parseResponse(json, definitions: []))
        }
    }

    private func makeEngine(_ transport: GeminiHistoryTransport) -> BoneGeminiInferenceEngine {
        .init(configuration: .init(kind: .google, apiKey: "synthetic", baseURL: URL(string: "https://synthetic.invalid")!, authenticationMode: .googleAPIKey), transport: transport)
    }
}

private struct GeminiHistoryTool: BoneAgentTool {
    struct Payload: Codable, Sendable {}
    typealias Input = Payload
    typealias Output = Payload
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(id: "echo", version: "1", title: "Echo", summary: "Synthetic echo",
        wireName: "echo", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    func execute(input: Input, context: Context) async throws -> Output { .init() }
}

private actor GeminiHistoryTransport: BoneInferenceHTTPTransport {
    let nativeIDs: Bool
    let signatures: Bool
    var bodies: [Data] = []
    let signatureTurns: Set<Int>
    init(nativeIDs: Bool, signatures: Bool, signatureTurns: Set<Int> = [1, 2]) {
        self.nativeIDs = nativeIDs; self.signatures = signatures; self.signatureTurns = signatureTurns
    }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        .init(statusCode: 200, data: try response(request), headers: [:])
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: [.init(data: String(decoding: try response(request), as: UTF8.self))], headers: [:])
    }
    private func response(_ request: URLRequest) throws -> Data {
        bodies.append(request.httpBody ?? Data())
        let index = bodies.count
        let part: [String: Any]
        if index > 2 { part = ["text": "done"] }
        else {
            var function: [String: Any] = ["name": "echo", "args": [:]]
            if nativeIDs { function["id"] = "native-\(index)" }
            var value: [String: Any] = ["functionCall": function]
            if signatures && signatureTurns.contains(index) { value["thoughtSignature"] = "signature-\(index)" }
            part = value
        }
        return try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["parts": [part]]]]])
    }
}
