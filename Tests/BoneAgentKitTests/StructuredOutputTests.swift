import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class StructuredOutputTests: XCTestCase {
    private let schema = BoneInferenceJSONSchema(
        name: "character_index",
        description: "角色索引",
        root: .object(
            properties: [
                "characters": .array(
                    items: .object(
                        properties: ["name": .string(enumValues: [], minimumLength: 1, maximumLength: 100)],
                        required: ["name"],
                        additionalProperties: false
                    ),
                    minimumItems: 0,
                    maximumItems: nil
                ),
            ],
            required: ["characters"],
            additionalProperties: false
        ),
        strict: true
    )

    func testRequestDefaultsToTextWhenLegacyPayloadHasNoResponseFormat() throws {
        let legacy = Data(#"{"modelID":"m","messages":[{"role":"user","content":"hi"}],"availableTools":[],"generationOptions":{}}"#.utf8)
        let request = try JSONDecoder().decode(BoneInferenceRequest.self, from: legacy)
        XCTAssertEqual(request.responseFormat, .text)
    }

    func testSchemaValidationRejectsInvalidName() {
        XCTAssertThrowsError(try BoneInferenceResponseFormat.jsonSchema(
            .init(name: "bad name", description: nil, root: schema.root, strict: true),
            fallback: .requireNative
        ).validated()) { error in
            XCTAssertEqual(error as? BoneInferenceError, .invalidStructuredOutputContract)
        }
    }

    func testOpenAIMapsJSONSchemaAndReturnsStructuredData() async throws {
        let transport = CapturingTransport(response: Self.openAIResponse(text: #"{"characters":[]}"#))
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind: .openAI), transport: transport)
        let response = try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .requireNative)))
        let body = try Self.requestBody(from: await transport.requestBodyData())
        let responseFormat = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let wrapper = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(wrapper["name"] as? String, "character_index")
        XCTAssertEqual(wrapper["strict"] as? Bool, true)
        XCTAssertStructuredCharacters(response)
    }

    /// 验证 OpenAI 原生 JSON Schema 响应缺字段或字段类型错误时不会作为成功数据返回。
    func testOpenAINativeJSONSchemaRejectsSchemaMismatch() async throws {
        /// 覆盖缺少必填字段与字段类型错误两类 Provider 违约响应。
        let invalidPayloads = [#"{}"#, #"{"characters":"invalid"}"#]
        for payload in invalidPayloads {
            let transport = CapturingTransport(response: Self.openAIResponse(text: payload))
            let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind: .openAI), transport: transport)

            await assertInvalidStructuredResponse {
                try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .requireNative)))
            }
        }
    }

    /// 验证 OpenAI 流式原生 JSON Schema 响应同样执行本地 Schema 复验。
    func testOpenAIStreamingNativeJSONSchemaRejectsSchemaMismatch() async throws {
        /// 覆盖缺少必填字段与字段类型错误两类流式响应。
        let invalidPayloads = [#"{}"#, #"{"characters":"invalid"}"#]
        for payload in invalidPayloads {
            let transport = CapturingTransport(events: Self.openAIStreamEvents(text: payload))
            let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind: .openAI), transport: transport)

            await assertInvalidStructuredResponse {
                try await engine.streamInference(request: request(format: .jsonSchema(schema, fallback: .requireNative)), options: .init())
            }
        }
    }

    func testOpenAICompatibleUsesForcedToolFallbackInsteadOfGuessingNativeField() async throws {
        let transport = CapturingTransport(response: Self.openAIToolResponse(arguments: ["characters": []]))
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind: .custom), transport: transport)
        let response = try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .nativeOrToolCall)))
        let body = try Self.requestBody(from: await transport.requestBodyData())
        XCTAssertNil(body["response_format"])
        let choice = try XCTUnwrap(body["tool_choice"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "function")
        XCTAssertEqual((choice["function"] as? [String: Any])?["name"] as? String, "submit_structured_result")
        XCTAssertStructuredCharacters(response)
    }

    func testGeminiMapsJSONSchemaAndReturnsStructuredData() async throws {
        let transport = CapturingTransport(response: Self.geminiResponse(text: #"{"characters":[]}"#))
        let engine = BoneGeminiInferenceEngine(configuration: configuration(kind: .google, authentication: .googleAPIKey), transport: transport)
        let response = try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .requireNative)))
        let body = try Self.requestBody(from: await transport.requestBodyData())
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertNotNil(config["responseSchema"] as? [String: Any])
        XCTAssertStructuredCharacters(response)
    }

    /// 验证 Gemini 原生 JSON Schema 响应缺字段或字段类型错误时不会作为成功数据返回。
    func testGeminiNativeJSONSchemaRejectsSchemaMismatch() async throws {
        /// 覆盖缺少必填字段与字段类型错误两类 Provider 违约响应。
        let invalidPayloads = [#"{}"#, #"{"characters":"invalid"}"#]
        for payload in invalidPayloads {
            let transport = CapturingTransport(response: Self.geminiResponse(text: payload))
            let engine = BoneGeminiInferenceEngine(configuration: configuration(kind: .google, authentication: .googleAPIKey), transport: transport)

            await assertInvalidStructuredResponse {
                try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .requireNative)))
            }
        }
    }

    /// 验证 Gemini 流式原生 JSON Schema 响应同样执行本地 Schema 复验。
    func testGeminiStreamingNativeJSONSchemaRejectsSchemaMismatch() async throws {
        /// 覆盖缺少必填字段与字段类型错误两类流式响应。
        let invalidPayloads = [#"{}"#, #"{"characters":"invalid"}"#]
        for payload in invalidPayloads {
            let transport = CapturingTransport(events: Self.geminiStreamEvents(text: payload))
            let engine = BoneGeminiInferenceEngine(configuration: configuration(kind: .google, authentication: .googleAPIKey), transport: transport)

            await assertInvalidStructuredResponse {
                try await engine.streamInference(request: request(format: .jsonSchema(schema, fallback: .requireNative)), options: .init())
            }
        }
    }

    /// 验证 MiniMax 无可靠原生或强制 Tool 契约时在联网前拒绝结构化请求。
    func testMiniMaxStructuredOutputFailsBeforeNetworkRequest() async throws {
        let transport = CapturingTransport(response: Self.anthropicTextResponse(text: #"{"characters":[]}"#))
        let engine = BoneAnthropicInferenceEngine(configuration: configuration(kind: .miniMax, authentication: .anthropicDual), transport: transport)
        do {
            _ = try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .nativeOrToolCall)))
            XCTFail("MiniMax 无法保证结构化契约时必须在联网前失败")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedStructuredOutput)
        }
        let captured = await transport.capturedRequest()
        XCTAssertNil(captured)
    }

    func testAnthropicToolStreamIgnoresThinkingAndSignatureBlocks() throws {
        let tool = try BoneStructuredOutputSupport.fallbackTool(
            for: .jsonSchema(schema, fallback: .nativeOrToolCall)
        )
        let events: [BoneInferenceEventStreamEvent] = [
            event("message_start", #"{"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}"#),
            event("content_block_start", #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"private reasoning"}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"opaque"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":0}"#),
            event("content_block_start", #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"call_1","name":"submit_structured_result","input":{}}}"#),
            event("content_block_delta", #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"characters\":[]}"}}"#),
            event("content_block_stop", #"{"type":"content_block_stop","index":1}"#),
            event("message_delta", #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}"#),
            event("message_stop", #"{"type":"message_stop"}"#),
        ]

        let response = try BoneAnthropicToolStreamAggregator.aggregate(
            events: events,
            definitions: [tool]
        )
        let structured = try BoneStructuredOutputSupport.structuredResponse(
            from: response,
            schema: schema.root
        )
        XCTAssertStructuredCharacters(structured)
    }

    /// 验证 MiniMax 流式结构化请求也在创建网络请求前失败。
    func testMiniMaxStreamingStructuredOutputFailsBeforeNetworkRequest() async throws {
        let transport = CapturingTransport(events: Self.openAIStreamEvents(text: #"{"characters":[]}"#))
        let engine = BoneAnthropicInferenceEngine(configuration: configuration(kind: .miniMax, authentication: .anthropicDual), transport: transport)
        do {
            _ = try await engine.streamInference(request: request(format: .jsonSchema(schema, fallback: .nativeOrToolCall)), options: .init())
            XCTFail("MiniMax 流式结构化请求必须在联网前失败")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedStructuredOutput)
        }
        let captured = await transport.capturedRequest()
        XCTAssertNil(captured)
    }

    func testAnthropicRequireNativeFailsBeforeNetworkRequest() async throws {
        let transport = CapturingTransport(response: Self.anthropicToolResponse(arguments: ["characters": []]))
        let engine = BoneAnthropicInferenceEngine(configuration: configuration(kind: .anthropic, authentication: .anthropicDual), transport: transport)
        do {
            _ = try await engine.infer(request: request(format: .jsonSchema(schema, fallback: .requireNative)))
            XCTFail("Anthropic 原生 JSON Schema 未核验时必须 fail closed")
        } catch let error as BoneInferenceError {
            XCTAssertEqual(error, .unsupportedStructuredOutput)
        }
        let captured = await transport.capturedRequest()
        XCTAssertNil(captured)
    }

    func testStrictJSONObjectNormalizerAcceptsDirectFenceAndUniqueWrappedObject() throws {
        let json = #"{"characters":[]}"#
        let cases: [(String, BoneStructuredJSONShape)] = [
            (json, .direct),
            ("```json\n\(json)\n```", .completeFence),
            ("Result follows:\n\(json)\nEnd.", .uniqueWrappedObject),
        ]
        for (text, shape) in cases {
            let result = try XCTUnwrap(BoneStructuredJSONObjectNormalizer.normalize(text))
            XCTAssertEqual(String(data: result.data, encoding: .utf8), json)
            XCTAssertEqual(result.shape, shape)
        }
    }

    func testStrictJSONObjectNormalizerRejectsAmbiguousOrDamagedText() {
        let rejected = [
            #"{"characters":["#,
            #"{"characters":[]} {"characters":[]}"#,
            #"[{"characters":[]}]"#,
            #"prefix [note] {"characters":[]}"#,
            #"{"characters":[],}"#,
            "no object",
        ]
        for text in rejected {
            XCTAssertNil(BoneStructuredJSONObjectNormalizer.normalize(text), text)
        }
    }

    func testStructuredOutputRejectsNonObjectModelText() async throws {
        let transport = CapturingTransport(response: Self.openAIResponse(text: "not-json"))
        let engine = BoneOpenAIInferenceEngine(configuration: configuration(kind: .openAI), transport: transport)
        do {
            _ = try await engine.infer(request: request(format: .jsonObject(fallback: .requireNative)))
            XCTFail("结构化输出必须验证 JSON 根对象")
        } catch let error as BoneInferenceTransportError {
            XCTAssertEqual(error, .invalidResponse)
        }
    }

    private func event(_ name: String, _ data: String) -> BoneInferenceEventStreamEvent {
        .init(event: name, id: nil, data: data)
    }

    private func request(format: BoneInferenceResponseFormat) -> BoneInferenceRequest {
        .init(
            modelID: "test-model",
            messages: [.init(role: .user, content: "extract")],
            generationOptions: .init(maximumOutputTokens: 1024),
            responseFormat: format
        )
    }

    private func configuration(
        kind: BoneInferenceProviderKind,
        authentication: BoneInferenceAuthenticationMode = .bearer
    ) -> BoneInferenceProviderConfiguration {
        .init(
            kind: kind,
            apiKey: "test-key",
            baseURL: URL(string: "https://synthetic.invalid")!,
            authenticationMode: authentication,
            endpointSecurityPolicy: .custom
        )
    }

    private func XCTAssertStructuredCharacters(
        _ response: BoneInferenceResponse,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .structured(result) = response,
              let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any] else {
            return XCTFail("应返回结构化 JSON 对象", file: file, line: line)
        }
        XCTAssertNotNil(object["characters"], file: file, line: line)
    }

    /// 断言异步结构化输出操作以安全的无效响应错误失败。
    /// - Parameter operation: 待执行的结构化推理操作。
    private func assertInvalidStructuredResponse(
        _ operation: () async throws -> BoneInferenceResponse
    ) async {
        do {
            _ = try await operation()
            XCTFail("不满足 Schema 的结构化响应不得作为成功数据返回")
        } catch let error as BoneInferenceTransportError {
            XCTAssertEqual(error, .invalidResponse)
        } catch {
            XCTFail("结构化响应应映射为稳定的无效响应错误：\(error)")
        }
    }

    /// 在测试调用方隔离域内解析请求 JSON，避免动态 Foundation 容器跨 actor 传递。
    private static func requestBody(from data: Data?) throws -> [String: Any] {
        guard let data,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return body
    }

    private static func openAIResponse(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ])
    }

    private static func openAIToolResponse(arguments: [String: Any]) -> Data {
        let encoded = String(data: try! JSONSerialization.data(withJSONObject: arguments), encoding: .utf8)!
        return try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "tool_calls": [[
                        "id": "call_1",
                        "type": "function",
                        "function": ["name": "submit_structured_result", "arguments": encoded],
                    ]],
                ],
                "finish_reason": "tool_calls",
            ]],
        ])
    }

    private static func geminiResponse(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": text]]], "finishReason": "STOP"]],
        ])
    }

    /// 构造 OpenAI 流式文本响应事件。
    /// - Parameter text: Provider 返回的完整文本。
    /// - Returns: 可供流式聚合器消费的事件序列。
    private static func openAIStreamEvents(text: String) -> [BoneInferenceEventStreamEvent] {
        let data = try! JSONSerialization.data(withJSONObject: [
            "choices": [[
                "delta": ["content": text],
                "finish_reason": "stop",
            ]],
        ])
        return [
            .init(data: String(decoding: data, as: UTF8.self)),
            .init(data: "[DONE]"),
        ]
    }

    /// 构造 Gemini 流式文本响应事件。
    /// - Parameter text: Provider 返回的完整文本。
    /// - Returns: 可供流式聚合器消费的事件序列。
    private static func geminiStreamEvents(text: String) -> [BoneInferenceEventStreamEvent] {
        let data = try! JSONSerialization.data(withJSONObject: [
            "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1],
            "candidates": [[
                "finishReason": "STOP",
                "content": ["role": "model", "parts": [["text": text]]],
            ]],
        ])
        return [.init(data: String(decoding: data, as: UTF8.self))]
    }

    private static func anthropicTextResponse(text: String) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
        ])
    }

    private static func anthropicToolResponse(arguments: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "content": [[
                "type": "tool_use",
                "id": "call_1",
                "name": "submit_structured_result",
                "input": arguments,
            ]],
            "stop_reason": "tool_use",
        ])
    }
}

private actor CapturingTransport: BoneInferenceHTTPTransport {
    /// 非流式响应体。
    private let response: Data
    /// 流式响应事件。
    private let events: [BoneInferenceEventStreamEvent]
    /// 最近一次真正发送的请求；预检失败时保持为空。
    private var request: URLRequest?

    /// 创建同时支持同步与流式测试的传输替身。
    /// - Parameters:
    ///   - response: 非流式响应体。
    ///   - events: 流式响应事件。
    init(response: Data = Data(), events: [BoneInferenceEventStreamEvent] = []) {
        self.response = response
        self.events = events
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        self.request = request
        return .init(statusCode: 200, data: response, headers: [:])
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        self.request = request
        return .init(statusCode: 200, events: events, headers: [:])
    }

    func sendRetryableForModels(
        _ request: URLRequest
    ) async throws -> BoneInferenceHTTPResponse {
        try await send(request)
    }

    func capturedRequest() -> URLRequest? { request }

    /// 只跨 actor 返回 Sendable 原始数据；动态 JSON 容器由调用方本地解析。
    func requestBodyData() -> Data? { request?.httpBody }
}
