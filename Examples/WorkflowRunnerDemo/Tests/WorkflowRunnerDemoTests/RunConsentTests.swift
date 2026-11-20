import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct RunConsentTests {
    @Test func oneApprovalCoversSearchAndPagesThenNextSendAsksAgain() async throws {
        let settings = Self.settings()
        let provider = RunConsentProvider(responses: [
            try tool("web_fetch", ["url": "https://example.com/first"], id: "a"),
            try tool("web_search", ["query": "test", "count": 1, "page": 0], id: "b"),
            try tool("web_fetch", ["url": "https://example.org/second"], id: "c"), try text("第一轮完成"),
            try tool("web_fetch", ["url": "https://example.com/third"], id: "d"), try text("第二轮完成")
        ])
        let approvals = RunConsentApprovals(); let web = RunConsentWeb()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key", transport: provider,
            toolInteractions: approvals.handlers, searchAPIKey: "fixture-search-key", webTransport: web)
        let first = try await session.send("第一轮")
        #expect(first.toolCalls == 3 && first.steps == 4)
        #expect(await approvals.requests.count == 1)
        #expect(await web.count == 3)
        let request = try #require(await approvals.requests.first)
        #expect(request.title == "允许本次任务联网？")
        #expect(request.detail.contains("example.com") && request.detail.contains("example.org") && request.detail.contains("Brave"))
        let second = try await session.send("第二轮")
        #expect(second.toolCalls == 1 && second.steps == 2)
        #expect(await approvals.requests.count == 2)
        #expect(await web.count == 4)
        #expect(await provider.count == 6)
        #expect(await session.failureDiagnostic() == nil)
    }

    @Test func repeatingNetworkToolStopsWithOneApprovalAndSpecificStepReason() async throws {
        let responses = try (0..<6).map { try tool("web_fetch", ["url": "https://example.com/page"], id: "loop-\($0)") }
        let provider = RunConsentProvider(responses: responses)
        let approvals = RunConsentApprovals(); let web = RunConsentWeb()
        let session = try await DemoLiveChatSession.make(settings: Self.settings(), apiKey: "fixture-key", transport: provider,
            toolInteractions: approvals.handlers, searchAPIKey: "fixture-search-key", webTransport: web)
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.send("loop") }
        let record = try #require(await session.failureDiagnostic())
        #expect(record.code == .inferenceSteps)
        #expect(record.inferenceResponses == 6 && record.completedTools == 6 && record.toolPreparations == 6)
        #expect(record.networkConfirmations == 1)
        #expect(record.message.contains("6 次"))
        #expect(await approvals.requests.count == 1)
        #expect(await provider.count == 6)
        await #expect(throws: DemoLiveChatFailure.limitReached) { try await session.send("do not replay") }
        #expect(await provider.count == 6)
    }

    @Test func approvedRunStillRejectsOtherHostsAndProvidersAndBindsEachGrant() async throws {
        let effects = DemoToolEffectStore(); let settings = Self.settings()
        let run = await effects.beginRun(scope: .init(settings: settings))
        let approvals = RunConsentApprovals()
        let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
        let first = try fetchCall("https://example.com/a", id: "a")
        let second = try fetchCall("https://example.org/b", id: "b")
        let definition = BoneWebFetchTool<BoneAgentEmptyContext>.definition
        let a = try #require(await effects.context(for: first, definition: definition, handlers: approvals.handlers, webPolicy: policy))
        let b = try #require(await effects.context(for: second, definition: definition, handlers: approvals.handlers, webPolicy: policy))
        #expect(a.effectID != b.effectID && a.authorizationNonce != b.authorizationNonce)
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: effects)
        _ = try await pipeline.execute(arguments: first.arguments, definition: definition, context: a) { Data("{}".utf8) }
        _ = try await pipeline.execute(arguments: second.arguments, definition: definition, context: b) { Data("{}".utf8) }
        await #expect(throws: BoneWorkflowToolExecutionError.authorizationRejected) {
            try await pipeline.execute(arguments: second.arguments, definition: definition, context: a) { Data("{}".utf8) }
        }
        let forbidden = try fetchCall("https://another.example.net/a", id: "forbidden")
        await #expect(throws: BoneWebError.hostNotAllowed) {
            try await effects.context(for: forbidden, definition: definition, handlers: approvals.handlers, webPolicy: policy)
        }
        let search = BoneInferenceToolCall(id: "search", toolID: "web.search", arguments: Data(#"{"query":"test"}"#.utf8))
        await #expect(throws: BoneAuthorizationError.denied) {
            try await effects.context(for: search, definition: BoneWebSearchTool<BoneAgentEmptyContext>.definition,
                handlers: approvals.handlers, searchProvider: DemoSearchChannel.deepSeek.title)
        }
        #expect(await approvals.requests.count == 1)
        #expect(await effects.endRun(id: run) == 1)
    }

    @Test func declinedRunDoesNotPromptAgainAndEndedRunCannotAuthorize() async throws {
        let effects = DemoToolEffectStore(); let settings = Self.settings()
        let run = await effects.beginRun(scope: .init(settings: settings))
        let approvals = RunConsentApprovals(allow: false)
        let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
        let call = try fetchCall("https://example.com/a", id: "a")
        for _ in 0..<2 {
            await #expect(throws: BoneAuthorizationError.denied) {
                try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition,
                    handlers: approvals.handlers, webPolicy: policy)
            }
        }
        #expect(await approvals.requests.count == 1)
        await effects.endRun(id: run)
        await #expect(throws: CancellationError.self) {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition,
                handlers: approvals.handlers, webPolicy: policy)
        }
        #expect(await approvals.requests.count == 1)
    }

    @Test(.timeLimit(.minutes(1))) func concurrentRequestsSharePendingConfirmation() async throws {
        let effects = DemoToolEffectStore(); let settings = Self.settings()
        let run = await effects.beginRun(scope: .init(settings: settings))
        let gate = RunConsentGate()
        let handlers = DemoToolInteractionHandlers(ask: { _ in throw CancellationError() }, authorize: { _ in await gate.wait() })
        let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
        let a = try fetchCall("https://example.com/a", id: "a")
        let b = try fetchCall("https://example.org/b", id: "b")
        async let first = effects.context(for: a, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition, handlers: handlers, webPolicy: policy)
        async let second = effects.context(for: b, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition, handlers: handlers, webPolicy: policy)
        await gate.started()
        await gate.answer(true)
        let contexts = try await (first, second)
        #expect(contexts.0 != nil && contexts.1 != nil)
        #expect(await gate.count == 1)
        #expect(await effects.endRun(id: run) == 1)
    }

    @Test(.timeLimit(.minutes(1))) func lateAnswerCannotAuthorizeReplacementRun() async throws {
        let effects = DemoToolEffectStore(); let settings = Self.settings()
        _ = await effects.beginRun(scope: .init(settings: settings))
        let gate = RunConsentGate()
        let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
        let call = try fetchCall("https://example.com/a", id: "a")
        let pending = Task {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition,
                handlers: .init(ask: { _ in throw CancellationError() }, authorize: { _ in await gate.wait() }), webPolicy: policy)
        }
        await gate.started()
        let next = await effects.beginRun(scope: .init(settings: settings))
        let denied = RunConsentApprovals(allow: false)
        await #expect(throws: BoneAuthorizationError.denied) {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition,
                handlers: denied.handlers, webPolicy: policy)
        }
        await gate.answer(true)
        await #expect(throws: CancellationError.self) { try await pending.value }
        await #expect(throws: BoneAuthorizationError.denied) {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition,
                handlers: denied.handlers, webPolicy: policy)
        }
        #expect(await denied.requests.count == 1)
        #expect(await effects.endRun(id: next) == 1)
    }

    @Test(.timeLimit(.minutes(1))) func cancellationRejectsAnswerEvenIfHostIgnoresCancellation() async throws {
        let effects = DemoToolEffectStore(); let settings = Self.settings()
        let run = await effects.beginRun(scope: .init(settings: settings))
        let gate = RunConsentGate()
        let policy = try BoneWebHostPolicy(allowedHosts: settings.webHostNames)
        let call = try fetchCall("https://example.com/a", id: "a")
        let handlers = DemoToolInteractionHandlers(ask: { _ in throw CancellationError() }, authorize: { _ in await gate.wait() })
        let pending = Task {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition, handlers: handlers, webPolicy: policy)
        }
        await gate.started()
        pending.cancel()
        await gate.answer(true)
        await #expect(throws: CancellationError.self) { try await pending.value }
        await #expect(throws: BoneAuthorizationError.denied) {
            try await effects.context(for: call, definition: BoneWebFetchTool<BoneAgentEmptyContext>.definition, handlers: handlers, webPolicy: policy)
        }
        #expect(await gate.count == 1)
        #expect(await effects.endRun(id: run) == 1)
    }

    private static func settings() -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .customOpenAI; settings.baseURL = "https://consent-tests.invalid"; settings.modelID = "fixture"
        settings.managesContext = false; settings.usesStreaming = false
        settings.enablesWebFetch = true; settings.webAllowedHosts = "example.com example.org"
        settings.enablesWebSearch = true; settings.search.braveEnabled = true
        return settings
    }
    private func fetchCall(_ url: String, id: String) throws -> BoneInferenceToolCall {
        .init(id: id, toolID: "web.fetch", arguments: try JSONEncoder().encode(BoneWebFetchInput(url: url)))
    }
    private func tool(_ name: String, _ input: [String: Any], id: String) throws -> String {
        let args = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        return String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["index": 0, "message": ["role": "assistant", "tool_calls": [
            ["id": id, "type": "function", "function": ["name": name, "arguments": args]]
        ]], "finish_reason": "tool_calls"]]]), as: UTF8.self)
    }
    private func text(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["choices": [["index": 0,
            "message": ["role": "assistant", "content": text], "finish_reason": "stop"]]]), as: UTF8.self)
    }
}

private actor RunConsentApprovals {
    private(set) var requests: [DemoToolAuthorizationRequest] = []
    let allow: Bool
    init(allow: Bool = true) { self.allow = allow }
    nonisolated var handlers: DemoToolInteractionHandlers {
        .init(ask: { _ in throw CancellationError() }, authorize: { await self.approve($0) })
    }
    private func approve(_ request: DemoToolAuthorizationRequest) -> Bool { requests.append(request); return allow }
}

private actor RunConsentGate {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var resolved: Bool?
    private var readiness: [CheckedContinuation<Void, Never>] = []
    func wait() async -> Bool {
        count += 1
        if let resolved { return resolved }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            let pending = readiness; readiness = []
            for ready in pending { ready.resume() }
        }
    }
    func started() async {
        if count > 0 { return }
        await withCheckedContinuation { readiness.append($0) }
    }
    func answer(_ value: Bool) {
        resolved = value
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume(returning: value) }
    }
}

private actor RunConsentProvider: BoneInferenceHTTPTransport {
    private var responses: [String]
    private(set) var count = 0
    init(responses: [String]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse {
        count += 1
        guard !responses.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return .init(statusCode: 200, data: Data(responses.removeFirst().utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { try send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidResponse
    }
}

private actor RunConsentWeb: BoneWebHTTPTransport {
    private(set) var count = 0
    func send(request: URLRequest, maximumResponseBytes: Int) throws -> BoneWebHTTPResponse {
        count += 1
        let url = request.url!
        if url.host == "api.search.brave.com" {
            return .init(url: url, statusCode: 200, headers: ["Content-Type": "application/json"],
                body: Data(#"{"type":"search","web":{"results":[{"title":"test","url":"https://example.com/a","description":"fixture"}]}}"#.utf8))
        }
        return .init(url: url, statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data("fixture".utf8))
    }
}
