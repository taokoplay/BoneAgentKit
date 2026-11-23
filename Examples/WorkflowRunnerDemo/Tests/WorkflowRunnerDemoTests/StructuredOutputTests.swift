import Foundation
import Testing
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct StructuredOutputTests: Sendable {
    @Test
    func defaultPolicyValidatesOnceAndRequestsConfiguredSchema() async throws {
        let engine = StructuredTestEngine([.response(StructuredFixtures.validResponse)])
        var settings = StructuredFixtures.settings()
        settings.maximumOutputTokens = 8_192
        let result = try await DemoStructuredOutputService().run(source: "待整理原文", settings: settings, engine: engine)
        #expect(result.fields == StructuredFixtures.fields)
        #expect(result.receipt.outcome == .accepted)
        #expect(result.validationCount == 1)
        #expect(result.correctionCount == 0)
        #expect(result.inferenceCallCount == 1)
        let prettyJSON = try #require(result.prettyJSON)
        #expect(try JSONDecoder().decode(DemoStructuredSummary.self, from: Data(prettyJSON.utf8)) == StructuredFixtures.fields)
        #expect(prettyJSON.contains("\n"))
        let request = try #require(await engine.requests.first)
        #expect(request.modelID == settings.modelID)
        #expect(request.responseFormat == .jsonSchema(DemoStructuredOutputService.schema, fallback: .nativeOrToolCall))
        #expect(request.availableTools.isEmpty)
        #expect(request.generationOptions.maximumOutputTokens == 2_048)
        #expect(request.messages.last?.content == "待整理原文")
    }

    @Test
    func promptPresetIsIncludedInStructuredOutputRequests() async throws {
        let engine = StructuredTestEngine([.response(StructuredFixtures.validResponse)])
        var settings = StructuredFixtures.settings()
        settings.promptPreset = .softwareDeveloper
        settings.systemPrompt = "输出必须保持兼容。"

        _ = try await DemoStructuredOutputService().run(source: "待整理原文", settings: settings, engine: engine)

        let request = try #require(await engine.requests.first)
        #expect(request.messages.map(\.role) == [.system, .user])
        let system = try #require(request.messages.first?.content)
        #expect(system.contains("你是软件开发助手。"))
        #expect(system.contains("输出必须保持兼容。"))
        #expect(system.contains("将用户提供的原文整理为 summary 和 keyPoints。"))
    }

    @Test
    func correctionIsDisabledByDefaultAndRejectionIsNotSuccess() async throws {
        let engine = StructuredTestEngine([.response(StructuredFixtures.structured("{}")), .response(StructuredFixtures.validResponse)])
        let result = try await DemoStructuredOutputService().run(source: "原文", settings: StructuredFixtures.settings(), engine: engine)
        #expect(result.fields == nil)
        #expect(result.prettyJSON == nil)
        #expect(result.receipt.outcome == .rejected(.contractMismatch))
        #expect(result.validationCount == 1)
        #expect(result.correctionCount == 0)
        #expect(await engine.requests.count == 1)
    }

    @Test(arguments: ["{broken", "{}", #"{"summary":7,"keyPoints":[]}"#,
                      #"{"summary":"ok","keyPoints":[],"extra":true}"#,
                      #"{"summary":"  ","keyPoints":[]}"#,
                      #"{"summary":"ok","keyPoints":["\n "]}"#])
    func onlyKnownCompleteCandidateRejectionsGetOneCorrection(candidate: String) async throws {
        let engine = StructuredTestEngine([.response(StructuredFixtures.structured(candidate)), .response(StructuredFixtures.validResponse)])
        let result = try await DemoStructuredOutputService().run(
            source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: 1, engine: engine
        )
        #expect(result.fields == StructuredFixtures.fields)
        #expect(result.validationCount == 2)
        #expect(result.correctionCount == 1)
        #expect(result.inferenceCallCount == 2)
        let requests = await engine.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.modelID == StructuredFixtures.settings().modelID })
        #expect(requests.allSatisfy { $0.responseFormat == .jsonSchema(DemoStructuredOutputService.schema, fallback: .nativeOrToolCall) })
        #expect(requests[1].messages.contains { $0.role == .assistant && $0.content == candidate })
    }

    @Test
    func twoCorrectionsConsumeOnlyThreeActualCallsAndReturnFinalRejection() async throws {
        let rejected = StructuredTestEngine.Reply.response(StructuredFixtures.structured("{}"))
        let engine = StructuredTestEngine([rejected, rejected, rejected, .response(StructuredFixtures.validResponse)])
        let result = try await DemoStructuredOutputService().run(
            source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: 2, engine: engine
        )
        #expect(result.fields == nil)
        #expect(result.prettyJSON == nil)
        #expect(result.receipt.outcome == .rejected(.contractMismatch))
        #expect(result.validationCount == 3)
        #expect(result.correctionCount == 2)
        #expect(result.inferenceCallCount == 3)
        #expect(await engine.requests.count == 3)
    }

    @Test(arguments: [false, true])
    func realSDKProviderMapsSchemaAndLocallyValidatesWithoutNetwork(native: Bool) async throws {
        var settings = StructuredFixtures.settings(native: native)
        settings.maximumOutputTokens = 8_192
        let transport = StructuredTestTransport([.response(200, try StructuredFixtures.wireResponse(native: native))])
        let result = try await DemoStructuredOutputService().run(
            source: "原文", settings: settings, apiKey: "synthetic-test-key", transport: transport
        )
        #expect(result.fields == StructuredFixtures.fields)
        #expect(result.correctionCount == 0)
        let requests = await transport.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == settings.baseURL)
        let body = try StructuredFixtures.body(request)
        #expect(body["model"] as? String == settings.modelID)
        #expect(body["max_tokens"] as? Int == 2_048)
        #expect(body["stream"] == nil)
        let schema: [String: Any]
        if native {
            let format = try #require(body["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            let wrapper = try #require(format["json_schema"] as? [String: Any])
            #expect(wrapper["name"] as? String == "lab_source_summary")
            #expect(wrapper["strict"] as? Bool == true)
            schema = try #require(wrapper["schema"] as? [String: Any])
        } else {
            let tools = try #require(body["tools"] as? [[String: Any]])
            let function = try #require(tools.first?["function"] as? [String: Any])
            #expect(function["name"] as? String == "submit_structured_result")
            schema = try #require(function["parameters"] as? [String: Any])
        }
        #expect(Set(schema["required"] as? [String] ?? []) == ["summary", "keyPoints"])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(await transport.unexpectedPaths == 0)
    }

    @Test(arguments: [false, true])
    func knownLocalBlankFieldRejectionCorrectsUsingSameRealSDKModel(native: Bool) async throws {
        let transport = StructuredTestTransport([
            .response(200, try StructuredFixtures.wireResponse(native: native, text: #"{"summary":"   ","keyPoints":[]}"#)),
            .response(200, try StructuredFixtures.wireResponse(native: native))
        ])
        let settings = StructuredFixtures.settings(native: native)
        let result = try await DemoStructuredOutputService().run(
            source: "原文", settings: settings, apiKey: "synthetic-test-key", maximumCorrections: 1, transport: transport
        )
        #expect(result.fields == StructuredFixtures.fields)
        #expect(result.correctionCount == 1)
        #expect(result.validationCount == 2)
        #expect(result.inferenceCallCount == 2)
        let requests = await transport.requests
        try #require(requests.count == 2)
        for request in requests { #expect(try StructuredFixtures.body(request)["model"] as? String == settings.modelID) }
    }

    @Test(arguments: [BoneInferenceTransportError.invalidCredential, .httpStatus(401), .httpStatus(429),
                      .cancelled, .idleTimedOut, .invalidResponse, .outputTruncated])
    func transportAuthenticationCancellationAndAmbiguousFailuresPropagateWithoutCorrection(failure: BoneInferenceTransportError) async throws {
        let transport = StructuredTestTransport([.failure(failure)])
        do {
            _ = try await DemoStructuredOutputService().run(
                source: "原文", settings: StructuredFixtures.settings(), apiKey: "synthetic-test-key",
                maximumCorrections: 2, transport: transport
            )
            Issue.record("Operational failure unexpectedly produced a validation receipt")
        } catch { #expect(error as? BoneInferenceTransportError == failure) }
        #expect(await transport.requests.count == 1)
        #expect(await transport.unexpectedPaths == 0)
    }

    @Test
    func providerSchemaErrorAndTruncationAreNeverTreatedAsRepairableCandidates() async throws {
        for (text, finish, expected) in [
            (#"{"summary":7,"keyPoints":[]}"#, "stop", BoneInferenceTransportError.invalidResponse),
            (StructuredFixtures.json, "length", .outputTruncated)
        ] {
            let transport = StructuredTestTransport([
                .response(200, try StructuredFixtures.wireResponse(native: true, text: text, finishReason: finish))
            ])
            do {
                _ = try await DemoStructuredOutputService().run(
                    source: "原文", settings: StructuredFixtures.settings(native: true), apiKey: "synthetic-test-key",
                    maximumCorrections: 2, transport: transport
                )
                Issue.record("A provider-level failure unexpectedly returned a receipt")
            } catch { #expect(error as? BoneInferenceTransportError == expected) }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test
    func partialRefusedToolAndTextShapesCannotEnterProcessor() async throws {
        let data = Data(StructuredFixtures.json.utf8)
        let partial = BoneInferenceResponse.assistantTurn(
            turn: try .init(content: [.structured(data)]), finishReason: .length,
            usage: nil, refusal: nil, providerContinuation: nil
        )
        let refused = BoneInferenceResponse.assistantTurn(
            turn: try .init(content: [.structured(data)]), finishReason: .stop,
            usage: nil, refusal: .policy, providerContinuation: nil
        )
        let tool = BoneInferenceResponse.toolCall(.init(id: "test-call", toolID: "test-tool", arguments: Data("{}".utf8)))
        for shape in [partial, refused, tool, .finish(.init(text: StructuredFixtures.json))] {
            let engine = StructuredTestEngine([.response(shape), .response(StructuredFixtures.validResponse)])
            do {
                _ = try await DemoStructuredOutputService().run(
                    source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: 2, engine: engine
                )
                Issue.record("Non-complete structured shape unexpectedly entered validation")
            } catch { #expect(error as? DemoStructuredOutputError == .incompleteResponse) }
            #expect(await engine.requests.count == 1)
        }
    }

    @Test
    func unknownCorrectionFailureAndCancellationAfterCompleteDeliveryPropagate() async throws {
        for reply in [StructuredTestEngine.Reply.unknownFailure, .cancelAfterResponse] {
            let engine = StructuredTestEngine([.response(StructuredFixtures.structured("{}")), reply, .response(StructuredFixtures.validResponse)])
            let pending = Task {
                try await DemoStructuredOutputService().run(
                    source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: 2, engine: engine
                )
            }
            do {
                _ = try await pending.value
                Issue.record("Failed/cancelled correction unexpectedly returned a receipt")
            } catch {
                if case .unknownFailure = reply { #expect(error as? StructuredTestFailure == .unknown) }
                else { #expect(error is CancellationError) }
            }
            #expect(await engine.requests.count == 2)
        }
    }

    @Test
    func sourceCorrectionAndOutputBoundsFailBeforeAnyExtraCall() async throws {
        let engine = StructuredTestEngine([.response(StructuredFixtures.validResponse)])
        for limit in [-1, 3, Int.max] {
            do {
                _ = try await DemoStructuredOutputService().run(
                    source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: limit, engine: engine
                )
                Issue.record("Invalid correction limit unexpectedly accepted")
            } catch { #expect(error as? DemoStructuredOutputError == .invalidCorrectionLimit) }
        }
        for (source, expected) in [(" \n", DemoStructuredOutputError.emptySource),
                                   (String(repeating: "中", count: 5_462), .sourceTooLarge)] {
            do {
                _ = try await DemoStructuredOutputService().run(source: source, settings: StructuredFixtures.settings(), engine: engine)
                Issue.record("Invalid source unexpectedly accepted")
            } catch { #expect(error as? DemoStructuredOutputError == expected) }
        }
        #expect(await engine.requests.isEmpty)
        let exact = String(repeating: "x", count: DemoStructuredOutputService.maximumSourceBytes)
        let result = try await DemoStructuredOutputService().run(source: exact, settings: StructuredFixtures.settings(), engine: engine)
        #expect(result.fields != nil)
        let oversized = StructuredTestEngine([.response(.structured(.init(
            data: Data(repeating: 0x78, count: DemoStructuredOutputService.maximumResponseBytes + 1)
        )))])
        do {
            _ = try await DemoStructuredOutputService().run(
                source: "原文", settings: StructuredFixtures.settings(), maximumCorrections: 2, engine: oversized
            )
            Issue.record("Oversized response unexpectedly accepted")
        } catch { #expect(error as? DemoStructuredOutputError == .responseTooLarge) }
        #expect(await oversized.requests.count == 1)
    }
}

private enum StructuredFixtures {
    static let fields = DemoStructuredSummary(summary: "可验证的摘要", keyPoints: ["第一条", "第二条"])
    static let json = #"{"summary":"可验证的摘要","keyPoints":["第一条","第二条"]}"#
    static var validResponse: BoneInferenceResponse { structured(json) }

    static func structured(_ text: String) -> BoneInferenceResponse { .structured(.init(data: Data(text.utf8))) }

    static func settings(native: Bool = false) -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.selectProvider(native ? .openAI : .customOpenAI)
        settings.baseURL = "https://structured-output.invalid/explicit-endpoint"
        settings.usesFullEndpointURL = true
        settings.modelID = native ? "gpt-4o-mini" : "synthetic-configured-model"
        settings.systemPrompt = ""
        return settings
    }

    static func wireResponse(native: Bool, text: String = json, finishReason: String? = nil) throws -> Data {
        let message: [String: Any]
        if native { message = ["role": "assistant", "content": text] }
        else {
            message = ["role": "assistant", "content": NSNull(), "tool_calls": [[
                "id": "structured-1", "type": "function",
                "function": ["name": "submit_structured_result", "arguments": text]
            ]]]
        }
        return try JSONSerialization.data(withJSONObject: ["choices": [[
            "index": 0, "message": message, "finish_reason": finishReason ?? (native ? "stop" : "tool_calls")
        ]]])
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private enum StructuredTestFailure: Error, Equatable { case exhausted, unknown, unexpectedPath }

private actor StructuredTestEngine: BoneInferenceEngine {
    enum Reply: Sendable { case response(BoneInferenceResponse), unknownFailure, cancelAfterResponse }
    nonisolated var nonImageCapabilities: Set<BoneInferenceCapability> { [.text] }
    nonisolated var imageGenerator: (any BoneInferenceImageGenerating)? { nil }
    private var replies: [Reply]
    private(set) var requests: [BoneInferenceRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw StructuredTestFailure.exhausted }
        switch replies.removeFirst() {
        case .response(let response): return response
        case .unknownFailure: throw StructuredTestFailure.unknown
        case .cancelAfterResponse:
            withUnsafeCurrentTask { $0?.cancel() }
            return StructuredFixtures.validResponse
        }
    }
}

private actor StructuredTestTransport: BoneInferenceHTTPTransport {
    enum Reply: Sendable { case response(Int, Data), failure(BoneInferenceTransportError) }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var unexpectedPaths = 0

    init(_ replies: [Reply]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw StructuredTestFailure.exhausted }
        switch replies.removeFirst() {
        case .response(let status, let data): return .init(statusCode: status, data: data)
        case .failure(let failure): throw failure
        }
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        unexpectedPaths += 1
        throw StructuredTestFailure.unexpectedPath
    }

    func sendEventStream(
        _ request: URLRequest, options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        unexpectedPaths += 1
        throw StructuredTestFailure.unexpectedPath
    }
}
