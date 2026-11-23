import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct LiveChatTests: Sendable {
    @Test(arguments: [false, true])
    func chatUsesRealProviderAndRetainsTwoTurns(fullEndpoint: Bool) async throws {
        var settings = LiveChatFixtures.settings()
        settings.systemPrompt = " \n "
        settings.maximumOutputTokens = 768
        settings.usesFullEndpointURL = fullEndpoint
        if fullEndpoint { settings.baseURL = "https://live-chat.invalid/custom/completions" }
        let stub = LiveChatHTTPStub([
            .response(200, try LiveChatFixtures.text("第一轮回答")),
            .response(200, try LiveChatFixtures.text("第二轮回答")),
        ])
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: LiveChatFixtures.key, transport: LiveChatFixtures.transport(stub)
        )
        #expect(await stub.requests.isEmpty)
        let first = try await session.send("第一轮问题")
        let second = try await session.send("第二轮问题")
        #expect(first.text == "第一轮回答")
        #expect(first.steps == 1)
        #expect(first.toolCalls == 0)
        #expect(second.text == "第二轮回答")
        #expect(second.steps == 1)
        #expect(second.toolCalls == 0)

        let requests = await stub.requests
        try #require(requests.count == 2)
        for request in requests {
            #expect(request.url?.absoluteString == (fullEndpoint
                ? settings.baseURL : "https://live-chat.invalid/v1/chat/completions"))
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(LiveChatFixtures.key)")
            let body = try LiveChatFixtures.body(request)
            #expect(body["model"] as? String == settings.modelID)
            #expect(body["max_tokens"] as? Int == 768)
            #expect(body["tools"] == nil)
            #expect(body["stream"] == nil)
        }
        let firstMessages = try LiveChatFixtures.messages(requests[0])
        #expect(firstMessages.compactMap { $0["role"] as? String } == ["user"])
        #expect(firstMessages.first?["content"] as? String == "第一轮问题")
        let secondMessages = try LiveChatFixtures.messages(requests[1])
        #expect(secondMessages.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(secondMessages.compactMap { $0["content"] as? String } == ["第一轮问题", "第一轮回答", "第二轮问题"])
        #expect(await stub.retrySleeps == 0)
    }

    @Test
    func promptPresetCompilesWithCustomInstructionsIntoOneSystemMessage() async throws {
        var settings = LiveChatFixtures.settings()
        settings.promptPreset = .softwareDeveloper
        settings.systemPrompt = "项目约束：优先保持兼容。"
        let stub = LiveChatHTTPStub([.response(200, try LiveChatFixtures.text("已检查。"))])
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: LiveChatFixtures.key, transport: LiveChatFixtures.transport(stub)
        )

        _ = try await session.send("检查这个改动")

        let requests = await stub.requests
        try #require(requests.count == 1)
        let messages = try LiveChatFixtures.messages(requests[0])
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user"])
        let system = try #require(messages.first?["content"] as? String)
        #expect(system.contains("你是软件开发助手。"))
        #expect(system.contains("项目约束：优先保持兼容。"))
    }

    @Test
    func calculatorRunsLocallyAndPreservesToolHistory() async throws {
        var settings = LiveChatFixtures.settings()
        settings.systemPrompt = "请依据真实工具结果回答。"
        settings.enablesCalculator = true
        let stub = LiveChatHTTPStub([
            .response(200, try LiveChatFixtures.toolCall()),
            .response(200, try LiveChatFixtures.text("结果为 20。")),
            .response(200, try LiveChatFixtures.text("上一轮结果仍为 20。")),
        ])
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: LiveChatFixtures.key, transport: LiveChatFixtures.transport(stub)
        )
        let reply = try await session.send("用计算器计算 12 + 8")
        #expect(reply.text == "结果为 20。")
        #expect(reply.steps == 2)
        #expect(reply.toolCalls == 1)
        #expect(await session.toolFailureDiagnostic() == nil)
        let requests = await stub.requests
        try #require(requests.count == 2)
        let body = try LiveChatFixtures.body(requests[0])
        let tools = try #require(body["tools"] as? [[String: Any]])
        try #require(tools.count == 1)
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "math_calculate")
        let schema = try #require(function["parameters"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["expression"])
        let properties = try #require(schema["properties"] as? [String: [String: Any]])
        #expect(properties["expression"]?["type"] as? String == "string")

        let messages = try LiveChatFixtures.messages(requests[1])
        #expect(messages.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "tool"])
        #expect(messages.first?["content"] as? String == settings.systemPrompt)
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.first?["id"] as? String == "calculation-1")
        let tool = try #require(messages.first { $0["role"] as? String == "tool" })
        #expect(tool["tool_call_id"] as? String == "calculation-1")
        let resultText = try #require(tool["content"] as? String)
        let result = try JSONDecoder().decode(DemoCalculatorTool.Output.self, from: Data(resultText.utf8))
        #expect(result.value == 20)

        let next = try await session.send("刚才结果是多少？")
        #expect(next.steps == 1)
        #expect(next.toolCalls == 0)
        let allRequests = await stub.requests
        try #require(allRequests.count == 3)
        let history = try LiveChatFixtures.messages(allRequests[2])
        #expect(history.compactMap { $0["role"] as? String } == ["system", "user", "assistant", "tool", "assistant", "user"])
        let savedTool = try #require(history.first { $0["role"] as? String == "tool" })
        #expect(savedTool["content"] as? String == resultText)
        let savedAssistant = try #require(history.first { $0["tool_calls"] != nil })
        let savedCalls = try #require(savedAssistant["tool_calls"] as? [[String: Any]])
        let savedFunction = try #require(savedCalls.first?["function"] as? [String: Any])
        let arguments = try #require(savedFunction["arguments"] as? String)
        let input = try JSONDecoder().decode(BoneCalculatorTool<BoneAgentEmptyContext>.Input.self, from: Data(arguments.utf8))
        #expect(input.expression == "12.0 + 8.0")
    }

    @Test
    func disabledCalculatorRejectsForgedToolCall() async throws {
        let stub = LiveChatHTTPStub([.response(200, try LiveChatFixtures.toolCall())])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        #expect(await LiveChatFixtures.failure(session, text: "计算一下") == .invalidResponse)
        #expect(await LiveChatFixtures.failure(session, text: "再试一次") == .invalidResponse)
        let requests = await stub.requests
        try #require(requests.count == 1)
        let body = try LiveChatFixtures.body(requests[0])
        #expect(body["tools"] == nil)
        #expect(await stub.retrySleeps == 0)
    }

    @Test
    func invalidSettingsAndKeysAreRejectedBeforeTransport() async throws {
        let valid = LiveChatFixtures.settings()
        var insecure = valid
        insecure.baseURL = "http://live-chat.invalid"
        var embeddedCredential = valid
        embeddedCredential.baseURL = "https://account:password@live-chat.invalid"
        var queried = valid
        queried.baseURL = "https://live-chat.invalid?key=unsafe"
        var missingModel = valid
        missingModel.modelID = " \n "
        var invalidModel = valid
        invalidModel.modelID = "model\ninjected"
        let cases: [(DemoLiveChatSettings, String, DemoChatConfigurationError)] = [
            (insecure, LiveChatFixtures.key, .invalidURL),
            (embeddedCredential, LiveChatFixtures.key, .invalidURL),
            (queried, LiveChatFixtures.key, .invalidURL),
            (missingModel, LiveChatFixtures.key, .missingModel),
            (invalidModel, LiveChatFixtures.key, .missingModel),
            (valid, " \n ", .missingKey),
            (valid, "invalid\ncredential", .invalidKey),
        ]
        let stub = LiveChatHTTPStub([])
        for (settings, key, expected) in cases {
            do {
                _ = try await DemoLiveChatSession.make(
                    settings: settings, apiKey: key, transport: LiveChatFixtures.transport(stub)
                )
                Issue.record("Invalid settings unexpectedly created a session")
            } catch {
                #expect(error as? DemoLiveChatFailure == .configuration(expected))
            }
        }
        #expect(await stub.requests.isEmpty)
    }

    @Test
    func promptPresetIsCodableAndDefaultsToCustomForOldSettings() throws {
        var settings = LiveChatFixtures.settings()
        settings.promptPreset = .personalAssistant
        let encoded = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(DemoLiveChatSettings.self, from: encoded)
        #expect(restored.promptPreset == .personalAssistant)
        #expect(restored.promptProfile?.id == "personal-assistant")

        let old = try JSONSerialization.data(withJSONObject: [
            "provider": "OpenAICompatible",
            "baseURL": LiveChatFixtures.endpoint,
            "modelID": "unit-test-model",
            "systemPrompt": "旧说明"
        ])
        let decodedOld = try JSONDecoder().decode(DemoLiveChatSettings.self, from: old)
        #expect(decodedOld.promptPreset == .custom)
        #expect(decodedOld.promptProfile == nil)
    }

    @Test
    func settingsCodableContainsOnlyPreferences() throws {
        let settings = LiveChatFixtures.settings()
        let encoded = try JSONEncoder().encode(settings)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let preferenceKeys: Set<String> = [
            "provider", "baseURL", "modelID", "usesFullEndpointURL", "systemPrompt",
            "enablesCalculator", "maximumOutputTokens", "usesStreaming", "managesContext",
            "summarizesContext", "contextWindowTokens", "preservesConversation", "enablesTextResources",
        ]
        #expect(preferenceKeys.isSubset(of: Set(object.keys)))
        #expect(Set(object.keys).isDisjoint(with: ["apiKey", "credential", "messages", "conversationState", "resources", "imageData"]))
        #expect(!String(decoding: encoded, as: UTF8.self).contains(LiveChatFixtures.key))
        #expect(try JSONDecoder().decode(DemoLiveChatSettings.self, from: encoded) == settings)
    }

    @Test(arguments: [401, 429, 402, 404, 403])
    func httpFailuresAreSafeAndNeverRetried(status: Int) async throws {
        let expected: DemoLiveChatFailure
        switch status {
        case 401: expected = .authentication
        case 429: expected = .rateLimited
        case 402: expected = .quotaExceeded
        case 404: expected = .unsupportedModel
        default: expected = .unknown
        }
        let stub = LiveChatHTTPStub([.response(status, try LiveChatFixtures.json([
            "error": ["message": "\(LiveChatFixtures.key) \(LiveChatFixtures.endpoint) \(LiveChatFixtures.upstreamMarker)"],
        ]))])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let failure = await LiveChatFixtures.failure(session, text: "你好")
        #expect(failure == expected)
        LiveChatFixtures.expectSafe(failure)
        #expect(await LiveChatFixtures.failure(session, text: "再试一次") == expected)
        #expect(await stub.requests.count == 1)
        #expect(await stub.retrySleeps == 0)
    }

    @Test
    func networkFailureIsSafeAndNeverRetried() async throws {
        let stub = LiveChatHTTPStub([.network])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let failure = await LiveChatFixtures.failure(session, text: "你好")
        #expect(failure == .network)
        LiveChatFixtures.expectSafe(failure)
        #expect(await LiveChatFixtures.failure(session, text: "重试") == .network)
        #expect(await stub.requests.count == 1)
        #expect(await stub.retrySleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationReachesSuspendedTransportAndLocksSession() async throws {
        let suspension = LiveChatSuspension()
        let stub = LiveChatHTTPStub([.suspended(suspension)])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let pending = Task { try await session.send("等待响应") }
        defer { pending.cancel() }
        await suspension.waitUntilStarted()
        #expect(await stub.requests.count == 1)
        pending.cancel()
        do {
            _ = try await pending.value
            Issue.record("A cancelled transport unexpectedly returned a reply")
        } catch {
            #expect(error as? DemoLiveChatFailure == .cancelled)
        }
        #expect(await suspension.wasCancelled)
        #expect(await LiveChatFixtures.failure(session, text: "取消后再次发送") == .cancelled)
        #expect(await stub.requests.count == 1)
        #expect(await stub.retrySleeps == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func reentrantSendDoesNotStartAnotherRequest() async throws {
        let suspension = LiveChatSuspension()
        let stub = LiveChatHTTPStub([.suspended(suspension)])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let pending = Task { try await session.send("正在发送") }
        defer { pending.cancel() }
        await suspension.waitUntilStarted()
        #expect(await LiveChatFixtures.failure(session, text: "重复发送") == .unknown)
        await suspension.finish(body: try LiveChatFixtures.text("已完成"))
        let reply = try await pending.value
        #expect(reply.text == "已完成")
        #expect(await LiveChatFixtures.failure(session, text: "新问题") == .unknown)
        #expect(await stub.requests.count == 1)
    }

    @Test
    func credentialAccountChangesWithEndpointScope() {
        let settings = LiveChatFixtures.settings()
        var otherHost = settings
        otherHost.baseURL = "https://other-chat.invalid"
        var otherPath = settings
        otherPath.baseURL += "/another-endpoint"
        var fullEndpoint = settings
        fullEndpoint.usesFullEndpointURL = true
        var otherProtocol = settings
        otherProtocol.provider = .anthropic
        var otherModel = settings
        otherModel.modelID = "another-model"
        #expect(settings.credentialAccount != otherHost.credentialAccount)
        #expect(settings.credentialAccount != otherPath.credentialAccount)
        #expect(settings.credentialAccount != fullEndpoint.credentialAccount)
        #expect(settings.credentialAccount != otherProtocol.credentialAccount)
        #expect(settings.credentialAccount == otherModel.credentialAccount)
    }

    @Test(arguments: [" \n\t ", String(repeating: "界", count: 5_462)])
    func invalidUserInputNeverReachesTransport(text: String) async throws {
        let stub = LiveChatHTTPStub([])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let expected: DemoLiveChatFailure = text.utf8.count > 16_384 ? .limitReached : .unknown
        #expect(await LiveChatFixtures.failure(session, text: text) == expected)
        #expect(await LiveChatFixtures.failure(session, text: "有效输入") == expected)
        #expect(await stub.requests.isEmpty)
    }

    @Test
    func exactUserByteLimitIsAccepted() async throws {
        let stub = LiveChatHTTPStub([.response(200, try LiveChatFixtures.text("已收到"))])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        let reply = try await session.send(String(repeating: "a", count: DemoLiveChatSession.maximumUserMessageBytes))
        #expect(reply.text == "已收到")
        #expect(await stub.requests.count == 1)
    }

    @Test(arguments: ["", " \n\t "])
    func emptyRepliesAreRejectedAndLockSession(text: String) async throws {
        let stub = LiveChatHTTPStub([.response(200, try LiveChatFixtures.text(text))])
        let session = try await DemoLiveChatSession.make(
            settings: LiveChatFixtures.settings(), apiKey: LiveChatFixtures.key,
            transport: LiveChatFixtures.transport(stub)
        )
        #expect(await LiveChatFixtures.failure(session, text: "你好") == .invalidResponse)
        #expect(await LiveChatFixtures.failure(session, text: "重试") == .invalidResponse)
        #expect(await stub.requests.count == 1)
    }

    @Test
    func inferenceStepLimitStopsToolLoopWithoutSeventhRequest() async throws {
        var settings = LiveChatFixtures.settings()
        settings.enablesCalculator = true
        let responses = try (1...6).map {
            LiveChatHTTPStub.Reply.response(200, try LiveChatFixtures.toolCall(id: "calculation-\($0)"))
        }
        let stub = LiveChatHTTPStub(responses)
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: LiveChatFixtures.key, transport: LiveChatFixtures.transport(stub)
        )
        #expect(await LiveChatFixtures.failure(session, text: "持续计算") == .limitReached)
        #expect(await LiveChatFixtures.failure(session, text: "重试") == .limitReached)
        #expect(await stub.requests.count == 6)
        #expect(await stub.retrySleeps == 0)
    }

    @Test
    func divisionByZeroStopsBeforeSecondInference() async throws {
        var settings = LiveChatFixtures.settings()
        settings.enablesCalculator = true
        let stub = LiveChatHTTPStub([.response(200, try LiveChatFixtures.toolCall(operation: .divide, right: 0))])
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: LiveChatFixtures.key, transport: LiveChatFixtures.transport(stub)
        )
        #expect(await LiveChatFixtures.failure(session, text: "计算 12 / 0") == .toolFailed)
        #expect(await LiveChatFixtures.failure(session, text: "重试") == .toolFailed)
        #expect(await stub.requests.count == 1)
    }

    @Test
    func calculatorRejectsZeroNonFiniteAndOutOfRangeNumbers() async throws {
        let calculator = DemoCalculatorTool()
        _ = try DemoCalculatorTool.definition.validatedForModelExposure()
        #expect(DemoCalculatorTool.definition.impact == .ordinaryPublicRead)
        #expect(DemoCalculatorTool.definition.executionPolicy == .serial)
        let cases: [(DemoCalculatorTool.Input, DemoCalculatorTool.CalculationError)] = [
            (.init(operation: .divide, left: 1, right: 0), .divisionByZero),
            (.init(operation: .divide, left: 1, right: -0.0), .divisionByZero),
            (.init(operation: .add, left: .nan, right: 1), .invalidNumber),
            (.init(operation: .add, left: 1, right: .infinity), .invalidNumber),
            (.init(operation: .multiply, left: 1e13, right: 1), .invalidNumber),
            (.init(operation: .divide, left: 1e12, right: .leastNonzeroMagnitude), .nonFiniteResult),
        ]
        for (input, expected) in cases {
            do {
                _ = try await calculator.execute(input: input, context: BoneAgentEmptyContext())
                Issue.record("Invalid arithmetic unexpectedly succeeded")
            } catch {
                #expect(error as? DemoCalculatorTool.CalculationError == expected)
            }
        }
        for (operation, value) in [
            (DemoCalculatorTool.Operation.add, 10.0), (.subtract, 6.0), (.multiply, 16.0), (.divide, 4.0),
        ] {
            let result = try await calculator.execute(
                input: .init(operation: operation, left: 8, right: 2), context: BoneAgentEmptyContext()
            )
            #expect(result.value == value)
        }
    }
}

private enum LiveChatFixtures {
    static let key = "unit-test-credential-DO-NOT-USE"
    static let endpoint = "https://live-chat.invalid"
    static let upstreamMarker = "PRIVATE-UPSTREAM-BODY"

    static func settings() -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .customOpenAI
        settings.baseURL = endpoint
        settings.modelID = "unit-test-model"
        settings.systemPrompt = ""
        settings.usesStreaming = false
        settings.managesContext = false
        return settings
    }

    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }

    static func text(_ value: String) throws -> String {
        try json(["choices": [["index": 0, "message": ["role": "assistant", "content": value], "finish_reason": "stop"]]])
    }

    static func toolCall(
        id: String = "calculation-1", operation: DemoCalculatorTool.Operation = .add,
        left: Double = 12, right: Double = 8
    ) throws -> String {
        let symbol: String
        switch operation {
        case .add: symbol = "+"
        case .subtract: symbol = "-"
        case .multiply: symbol = "*"
        case .divide: symbol = "/"
        }
        let arguments = try json(["expression": "\(left) \(symbol) \(right)"])
        return try json(["choices": [[
            "index": 0,
            "message": ["role": "assistant", "content": NSNull(), "tool_calls": [[
                "id": id, "type": "function", "function": ["name": "math_calculate", "arguments": arguments],
            ]]],
            "finish_reason": "tool_calls",
        ]]])
    }

    static func transport(_ stub: LiveChatHTTPStub) -> BoneInferenceURLSessionTransport {
        BoneInferenceURLSessionTransport(
            loader: { request in try await stub.load(request) },
            sleeper: { _ in
                await stub.recordRetrySleep()
                throw LiveChatStubError.unexpectedRetry
            }
        )
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func messages(_ request: URLRequest) throws -> [[String: Any]] {
        let body = try body(request)
        return try #require(body["messages"] as? [[String: Any]])
    }

    static func failure(_ session: DemoLiveChatSession, text: String) async -> DemoLiveChatFailure? {
        do {
            _ = try await session.send(text)
            Issue.record("Expected a safe chat failure")
            return nil
        } catch {
            guard let safe = error as? DemoLiveChatFailure else {
                Issue.record("Session exposed an unexpected error type")
                return nil
            }
            return safe
        }
    }

    static func expectSafe(_ failure: DemoLiveChatFailure?) {
        guard let failure else {
            Issue.record("Expected a failure with a fixed safe message")
            return
        }
        #expect(!failure.message.contains(key))
        #expect(!failure.message.contains(endpoint))
        #expect(!failure.message.contains(upstreamMarker))
        #expect(!failure.message.contains("unit-test-model"))
        #expect(!failure.message.contains("https://"))
        #expect(!failure.message.isEmpty)
    }
}

private enum LiveChatStubError: Error {
    case unexpectedRequest
    case unexpectedRetry
}

private actor LiveChatHTTPStub {
    enum Reply: Sendable {
        case response(Int, String)
        case network
        case suspended(LiveChatSuspension)
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var retrySleeps = 0

    init(_ replies: [Reply]) { self.replies = replies }

    func recordRetrySleep() { retrySleeps += 1 }

    func load(_ request: URLRequest) async throws -> (Data, BoneInferenceHTTPResponseMetadata) {
        requests.append(request)
        guard !replies.isEmpty else { throw LiveChatStubError.unexpectedRequest }
        switch replies.removeFirst() {
        case .response(let status, let body):
            return (Data(body.utf8), .init(statusCode: status, headers: ["Content-Type": "application/json"]))
        case .network:
            throw URLError(.cannotConnectToHost, userInfo: [
                NSURLErrorFailingURLStringErrorKey: LiveChatFixtures.endpoint,
                NSLocalizedDescriptionKey: "\(LiveChatFixtures.key) \(LiveChatFixtures.upstreamMarker)",
            ])
        case .suspended(let suspension):
            return try await suspension.load()
        }
    }
}

/// A cancellation-aware loader with explicit readiness; no timing or real network.
private actor LiveChatSuspension {
    private var continuation: CheckedContinuation<(Data, BoneInferenceHTTPResponseMetadata), Error>?
    private var readiness: [CheckedContinuation<Void, Never>] = []
    private var hasStarted = false
    private(set) var wasCancelled = false

    func waitUntilStarted() async {
        if hasStarted { return }
        await withCheckedContinuation { readiness.append($0) }
    }

    func load() async throws -> (Data, BoneInferenceHTTPResponseMetadata) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                hasStarted = true
                let waiters = readiness
                readiness.removeAll()
                for waiter in waiters { waiter.resume() }
                if wasCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.continuation = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func finish(body: String) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: (Data(body.utf8), .init(statusCode: 200)))
    }

    private func cancel() {
        wasCancelled = true
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }
}
