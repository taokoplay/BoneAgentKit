import Foundation
import XCTest
@testable import BoneAgentKit

final class ProtocolShapeDiagnosticTests: XCTestCase {
    func testOpenAIDiagnosticContainsOnlyAllowlistedShapeMetadata() {
        let events = [
            BoneInferenceEventStreamEvent(data: #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"SECRET_ID","type":"function","function":{"name":"PRIVATE_TOOL","arguments":"NOVEL"}}]},"finish_reason":null}]}"#),
            BoneInferenceEventStreamEvent(data: #"{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}"#),
            BoneInferenceEventStreamEvent(data: "[DONE]"),
        ]
        let value = BoneInferenceProtocolShapeDiagnostic.openAI(events: events).summary
        XCTAssertTrue(value.contains("protocol=openai"))
        XCTAssertTrue(value.contains("events=3"))
        XCTAssertTrue(value.contains("doneSeen=true"))
        XCTAssertTrue(value.contains("finishReason=tool_calls:1"))
        XCTAssertTrue(value.contains("toolFragments=1"))
        XCTAssertTrue(value.contains("usageEvents=1"))
        for secret in ["SECRET_ID", "PRIVATE_TOOL", "NOVEL"] {
            XCTAssertFalse(value.contains(secret))
        }
    }

    func testOpenAIDiagnosticClassifiesInvalidEventWithoutPayload() {
        let events = [BoneInferenceEventStreamEvent(data: "PRIVATE-NOT-JSON")]
        let value = BoneInferenceProtocolShapeDiagnostic.openAI(
            events: events,
            failureStage: .eventJSON
        ).summary
        XCTAssertTrue(value.contains("failureStage=event_json"))
        XCTAssertTrue(value.contains("invalidJSONEvents=1"))
        XCTAssertFalse(value.contains("PRIVATE"))
    }

    func testOpenAINonStreamingDiagnosticContainsOnlyAllowlistedShapeMetadata() {
        let json: [String: Any] = [
            "choices": [[
                "index": 0,
                "finish_reason": "tool_calls",
                "message": [
                    "content": "PRIVATE_TEXT",
                    "tool_calls": [[
                        "id": "SECRET_ID",
                        "type": "function",
                        "function": ["name": "PRIVATE_TOOL", "arguments": "NOVEL"],
                    ]],
                ],
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 20],
        ]
        let value = BoneInferenceProtocolShapeDiagnostic.openAI(
            responseJSON: json,
            failureStage: .toolArgumentsJSON
        ).summary
        XCTAssertTrue(value.contains("protocol=openai"))
        XCTAssertTrue(value.contains("transport=nonstream"))
        XCTAssertTrue(value.contains("choices=1"))
        XCTAssertTrue(value.contains("finishReason=tool_calls:1"))
        XCTAssertTrue(value.contains("toolCallCount=1"))
        XCTAssertTrue(value.contains("usagePresent=true"))
        XCTAssertTrue(value.contains("failureStage=tool_arguments_json"))
        for secret in ["PRIVATE_TEXT", "SECRET_ID", "PRIVATE_TOOL", "NOVEL"] {
            XCTAssertFalse(value.contains(secret))
        }
    }

    func testOpenAIToolStreamEngineThrowsSafeProtocolShapeError() async throws {
        let events = [BoneInferenceEventStreamEvent(data: "PRIVATE-NOT-JSON")]
        let engine = BoneOpenAIInferenceEngine(
            configuration: .init(
                kind: .zhipu,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: ProtocolShapeStreamTransport(events: events)
        )
        let definition = BoneAgentToolDefinition(
            id: "probe",
            version: "1.0.0",
            title: "Probe",
            summary: "Probe",
            wireName: "probe",
            schemaVersion: 1,
            inputSchema: .object(properties: [:], required: [], additionalProperties: false)
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "PRIVATE_PROMPT")],
            availableTools: [definition]
        )

        do {
            _ = try await engine.streamInferenceDetailed(
                request: request,
                options: .init(firstEventTimeout: 1, idleTimeout: 1)
            )
            XCTFail("invalid stream must throw")
        } catch let error as BoneInferenceProtocolShapeError {
            XCTAssertTrue(error.diagnostic.summary.contains("protocol=openai"))
            XCTAssertTrue(error.diagnostic.summary.contains("failureStage=event_json"))
            XCTAssertFalse(error.diagnostic.summary.contains("PRIVATE"))
        }
    }

    func testAnthropicNonStreamingDiagnosticContainsOnlyAllowlistedShapeMetadata() {
        let json: [String: Any] = [
            "content": [[
                "type": "tool_use",
                "id": "SECRET_ID",
                "name": "PRIVATE_TOOL",
                "input": ["text": "NOVEL"],
            ]],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ]
        let value = BoneInferenceProtocolShapeDiagnostic.anthropic(
            responseJSON: json,
            failureStage: .toolIdentity
        ).summary
        XCTAssertTrue(value.contains("protocol=anthropic"))
        XCTAssertTrue(value.contains("transport=nonstream"))
        XCTAssertTrue(value.contains("contentPresent=true"))
        XCTAssertTrue(value.contains("contentBlockCount=1"))
        XCTAssertTrue(value.contains("blockTypes=tool_use:1"))
        XCTAssertTrue(value.contains("toolUseBlocks=1"))
        XCTAssertTrue(value.contains("stopReason=tool_use"))
        XCTAssertTrue(value.contains("usagePresent=true"))
        XCTAssertTrue(value.contains("failureStage=tool_identity"))
        for secret in ["SECRET_ID", "PRIVATE_TOOL", "NOVEL"] {
            XCTAssertFalse(value.contains(secret))
        }
    }

    func testAnthropicNonStreamingThinkingAndToolUseDeliversOnlyToolCall() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "thinking", "thinking": "PRIVATE_REASONING", "signature": "SECRET_SIGNATURE"],
                ["type": "tool_use", "id": "call_1", "name": "probe", "input": ["value": "candidate"]],
            ],
            "stop_reason": "tool_use",
            "usage": ["input_tokens": 10, "output_tokens": 20],
        ])
        let engine = BoneAnthropicInferenceEngine(
            configuration: .init(
                kind: .anthropic,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: ProtocolShapeResponseTransport(response: response)
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "scan")],
            availableTools: [Self.probeDefinition]
        )

        let result = try await engine.inferDetailed(request: request)
        guard case let .assistantTurn(turn, finishReason, _, _, _) = result.response else {
            return XCTFail("expected assistant turn")
        }
        XCTAssertEqual(finishReason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertEqual(turn.text, nil)
        XCTAssertNil(result.reasoning)
        let encoded = String(data: try JSONEncoder().encode(result.response), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("PRIVATE_REASONING"))
        XCTAssertFalse(encoded.contains("SECRET_SIGNATURE"))
    }

    func testAnthropicNonStreamingRedactedThinkingAndToolUseDeliversToolCall() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "redacted_thinking", "data": "PRIVATE_REDACTED"],
                ["type": "tool_use", "id": "call_1", "name": "probe", "input": [:]],
            ],
            "stop_reason": "tool_use",
        ])
        let result = try await anthropicEngine(response: response).inferDetailed(
            request: anthropicToolRequest()
        )
        guard case let .assistantTurn(turn, finishReason, _, _, _) = result.response else {
            return XCTFail("expected assistant turn")
        }
        XCTAssertEqual(finishReason, .toolCalls)
        XCTAssertEqual(turn.toolCalls.count, 1)
        XCTAssertFalse((String(data: try JSONEncoder().encode(result.response), encoding: .utf8) ?? "").contains("PRIVATE"))
    }

    func testAnthropicNonStreamingPureThinkingStillFailsClosed() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [["type": "thinking", "thinking": "PRIVATE_REASONING"]],
            "stop_reason": "tool_use",
        ])
        do {
            _ = try await anthropicEngine(response: response).inferDetailed(request: anthropicToolRequest())
            XCTFail("pure thinking must not become a successful business response")
        } catch let error as BoneInferenceProtocolShapeError {
            XCTAssertTrue(error.diagnostic.summary.contains("failureStage=assistant_turn"))
            XCTAssertFalse(error.diagnostic.summary.contains("PRIVATE_REASONING"))
        }
    }

    func testAnthropicNonStreamingUnknownBlockStillFailsClosed() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "content": [
                ["type": "mystery", "payload": "PRIVATE_UNKNOWN"],
                ["type": "tool_use", "id": "call_1", "name": "probe", "input": [:]],
            ],
            "stop_reason": "tool_use",
        ])
        do {
            _ = try await anthropicEngine(response: response).inferDetailed(request: anthropicToolRequest())
            XCTFail("unknown block must remain rejected")
        } catch let error as BoneInferenceProtocolShapeError {
            XCTAssertTrue(error.diagnostic.summary.contains("failureStage=block_shape"))
            XCTAssertFalse(error.diagnostic.summary.contains("PRIVATE_UNKNOWN"))
        }
    }

    func testAnthropicToolNonStreamingEngineThrowsSafeProtocolShapeError() async throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": "PRIVATE_OPENAI_SHAPE"]]],
        ])
        let engine = BoneAnthropicInferenceEngine(
            configuration: .init(
                kind: .anthropic,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: ProtocolShapeResponseTransport(response: response)
        )
        let definition = BoneAgentToolDefinition(
            id: "probe",
            version: "1.0.0",
            title: "Probe",
            summary: "Probe",
            wireName: "probe",
            schemaVersion: 1,
            inputSchema: .object(properties: [:], required: [], additionalProperties: false)
        )
        let request = BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "PRIVATE_PROMPT")],
            availableTools: [definition]
        )

        do {
            _ = try await engine.inferDetailed(request: request)
            XCTFail("invalid response must throw")
        } catch let error as BoneInferenceProtocolShapeError {
            XCTAssertTrue(error.diagnostic.summary.contains("protocol=anthropic"))
            XCTAssertTrue(error.diagnostic.summary.contains("transport=nonstream"))
            XCTAssertTrue(error.diagnostic.summary.contains("failureStage=content_shape"))
            XCTAssertFalse(error.diagnostic.summary.contains("PRIVATE"))
        }
    }

    func testAnthropicDiagnosticContainsOnlyAllowlistedShapeMetadata() {
        let events = [
            BoneInferenceEventStreamEvent(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"PRIVATE","signature":"SECRET"}}"#),
            BoneInferenceEventStreamEvent(event: "content_block_delta", data: #"{"type":"content_block_delta","index":0,"delta":{"type":"mystery_delta","text":"NOVEL","partial_json":"TOOL_SECRET"}}"#),
            BoneInferenceEventStreamEvent(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":null}}"#),
        ]
        let value = BoneInferenceProtocolShapeDiagnostic.anthropic(events: events).summary
        XCTAssertTrue(value.contains("events=3"))
        XCTAssertTrue(value.contains("types=content_block_delta:1,content_block_start:1,message_delta:1"))
        XCTAssertTrue(value.contains("blocks=thinking:1"))
        XCTAssertTrue(value.contains("deltas=mystery_delta:1"))
        XCTAssertTrue(value.contains("stopReason=null:1"))
        for secret in ["PRIVATE", "SECRET", "NOVEL", "TOOL_SECRET"] {
            XCTAssertFalse(value.contains(secret))
        }
    }

    func testStructuredFailureClassificationUsesNormalizedObjectBeforeSchemaValidation() throws {
        let schema = BoneToolSchema.object(
            properties: ["characters": .array(items: .string(enumValues: [], minimumLength: nil, maximumLength: nil), minimumItems: 0, maximumItems: nil)],
            required: ["characters"],
            additionalProperties: false
        )
        let wrapped = "```json\n{\"unexpected\":true}\n```"
        let result = BoneInferenceStructuredValidationFailure.diagnose(
            text: wrapped,
            schema: schema
        )
        XCTAssertEqual(result.failure, .schemaMismatch)
        XCTAssertEqual(result.schemaMismatch, .init(path: "$.characters", rule: .missingRequired))
    }

    func testStructuredFailureClassificationContainsNoModelContent() {
        let schema = BoneToolSchema.object(
            properties: ["characters": BoneToolSchema.array(
                items: .string(enumValues: [], minimumLength: nil, maximumLength: nil),
                minimumItems: nil,
                maximumItems: nil
            )],
            required: ["characters"],
            additionalProperties: false
        )
        let cases: [(Data, BoneInferenceStructuredValidationFailure)] = [
            (Data("PRIVATE-NOT-JSON".utf8), .invalidJSON),
            (Data("[\"PRIVATE\"]".utf8), .rootNotObject),
            (Data("{\"SECRET\":true}".utf8), .schemaMismatch),
        ]
        for (data, expected) in cases {
            let value = BoneInferenceProtocolShapeDiagnostic.anthropic(
                events: [],
                structuredFailure: BoneInferenceStructuredValidationFailure.classify(data: data, schema: schema)
            ).summary
            XCTAssertTrue(value.contains("structuredFailure=\(expected.rawValue)"))
            XCTAssertFalse(value.contains("PRIVATE"))
            XCTAssertFalse(value.contains("SECRET"))
        }
    }

    func testSchemaMismatchDiagnosticReportsSafeSchemaPathAndRule() throws {
        let evidence = BoneToolSchema.object(
            properties: [
                "paragraphRef": .string(enumValues: [], minimumLength: 1, maximumLength: 64),
                "selectedText": .string(enumValues: [], minimumLength: 1, maximumLength: 1_200),
            ],
            required: ["paragraphRef", "selectedText"],
            additionalProperties: false
        )
        let schema = BoneToolSchema.object(
            properties: [
                "characters": .array(
                    items: .object(
                        properties: ["nameEvidence": .array(items: evidence, minimumItems: 1, maximumItems: 8)],
                        required: ["nameEvidence"],
                        additionalProperties: false
                    ),
                    minimumItems: 0,
                    maximumItems: nil
                ),
            ],
            required: ["characters"],
            additionalProperties: false
        )
        let data = Data(#"{"characters":[{"nameEvidence":[{"paragraphRef":"c0-p0"}]}]}"#.utf8)
        XCTAssertEqual(
            BoneToolSchemaValidator.firstMismatch(arguments: data, against: schema),
            .init(path: "$.characters[*].nameEvidence[*].selectedText", rule: .missingRequired)
        )
    }

    func testSchemaMismatchDiagnosticNeverIncludesUnknownPropertyNameOrValue() throws {
        let schema = BoneToolSchema.object(
            properties: ["characters": .array(items: .string(enumValues: [], minimumLength: nil, maximumLength: nil), minimumItems: 0, maximumItems: nil)],
            required: ["characters"],
            additionalProperties: false
        )
        let data = Data(#"{"characters":[],"PRIVATE_UNKNOWN_KEY":"SECRET_VALUE"}"#.utf8)
        let mismatch = try XCTUnwrap(BoneToolSchemaValidator.firstMismatch(arguments: data, against: schema))
        XCTAssertEqual(mismatch, .init(path: "$.*", rule: .unexpectedProperty))
        XCTAssertFalse(mismatch.path.contains("PRIVATE"))
        XCTAssertFalse(mismatch.path.contains("SECRET"))
    }

    func testAnthropicDiagnosticAppendsOnlySafeSchemaMismatchMetadata() {
        let value = BoneInferenceProtocolShapeDiagnostic.anthropic(
            events: [],
            structuredFailure: .schemaMismatch,
            schemaMismatch: .init(path: "$.characters[*].identitySummary.evidence.selectedText", rule: .stringLength)
        ).summary
        XCTAssertTrue(value.contains("schemaPath=$.characters[*].identitySummary.evidence.selectedText"))
        XCTAssertTrue(value.contains("schemaRule=stringLength"))
    }

    private func anthropicEngine(response: Data) -> BoneAnthropicInferenceEngine {
        BoneAnthropicInferenceEngine(
            configuration: .init(
                kind: .anthropic,
                apiKey: "test",
                baseURL: URL(string: "https://synthetic.invalid/v1")!
            ),
            transport: ProtocolShapeResponseTransport(response: response)
        )
    }

    private func anthropicToolRequest() -> BoneInferenceRequest {
        BoneInferenceRequest(
            modelID: "model",
            messages: [.init(role: .user, content: "scan")],
            availableTools: [Self.probeDefinition]
        )
    }

    private static let probeDefinition = BoneAgentToolDefinition(
        id: "probe",
        version: "1.0.0",
        title: "Probe",
        summary: "Probe",
        wireName: "probe",
        schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: true)
    )

    func testEmptyEventDiagnosticIsExplicit() {
        XCTAssertEqual(
            BoneInferenceProtocolShapeDiagnostic.anthropic(events: []).summary,
            "protocol=anthropic events=0 types=none blocks=none deltas=none stopReason=absent"
        )
    }
}

private struct ProtocolShapeResponseTransport: BoneInferenceHTTPTransport {
    let response: Data

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        .init(statusCode: 200, data: response)
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: [])
    }
}

private struct ProtocolShapeStreamTransport: BoneInferenceHTTPTransport {
    let events: [BoneInferenceEventStreamEvent]

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        .init(statusCode: 200, data: Data("{}".utf8))
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        .init(statusCode: 200, events: events)
    }
}
