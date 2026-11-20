import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct ToolFailureTests {
    @Test(arguments: [false, true])
    func unallowedHostIsDiagnosedBeforeApprovalAndHTTP(miniMaxStreaming: Bool) async throws {
        var settings = Self.settings()
        settings.enablesWebFetch = true; settings.webAllowedHosts = "example.com"
        if miniMaxStreaming {
            settings.provider = .init(rawValue: "MiniMax")
            settings.modelID = "MiniMax-M3.1-Flash"; settings.usesStreaming = true
            settings.systemPrompt = "保留助手说明"
        }
        let provider = ToolFailureProvider(name: "web_fetch", arguments: #"{"url":"https://weather.example.org/private?token=PRIVATE-DIAGNOSTIC-MARKER"}"#)
        let approvals = ToolFailureCounter()
        let web = ToolFailureWebTransport()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key",
            transport: provider, toolInteractions: .init(ask: { _ in throw BoneAskUserError.unavailable },
                authorize: { _ in await approvals.mark(); return true }), webTransport: web)
        let result = await failure(session)
        #expect(result == .toolFailed)
        let diagnostic = try #require(await session.toolFailureDiagnostic())
        #expect(diagnostic == .init(tool: .webFetch, reason: .hostNotAllowed))
        #expect(diagnostic.needsNetworkSettings && diagnostic.offersSearch)
        #expect(await approvals.count == 0)
        #expect(await web.count == 0)
        #expect(await provider.count == 1)
        #expect(await failure(session) == .toolFailed)
        #expect(await provider.count == 1)
        #expect(!settings.enablesWebSearch && !settings.search.automaticEnabled)
        let request = try #require(await provider.requestBodies.first)
        let body = String(decoding: request, as: UTF8.self)
        #expect(body.contains("本次未注册自动搜索工具"))
        if miniMaxStreaming {
            let object = try #require(JSONSerialization.jsonObject(with: request) as? [String: Any])
            let system = try #require(object["system"] as? String)
            #expect(system.contains("保留助手说明") && system.contains("web.fetch"))
        }
        #expect(!String(reflecting: diagnostic).contains("PRIVATE-DIAGNOSTIC-MARKER"))
        #expect(!diagnostic.message.contains("https://"))
    }

    @Test(arguments: [false, true])
    func denialAndHTTPFailureRemainDistinctAndNeverRetry(allow: Bool) async throws {
        var settings = Self.settings()
        settings.enablesWebFetch = true; settings.webAllowedHosts = "example.com"
        let provider = ToolFailureProvider(name: "web_fetch", arguments: #"{"url":"https://example.com/article"}"#)
        let approvals = ToolFailureCounter()
        let web = ToolFailureWebTransport()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key",
            transport: provider, toolInteractions: .init(ask: { _ in throw BoneAskUserError.unavailable },
                authorize: { _ in await approvals.mark(); return allow }), webTransport: web)
        #expect(await failure(session) == .toolFailed)
        let diagnostic = try #require(await session.toolFailureDiagnostic())
        #expect(diagnostic == .init(tool: .webFetch, reason: allow ? .httpFailure : .notAuthorized, requiresOutcomeReview: allow))
        #expect(await approvals.count == 1)
        #expect(await web.count == (allow ? 1 : 0))
        #expect(await provider.count == 1)
        #expect(!String(reflecting: diagnostic).contains("PRIVATE-DIAGNOSTIC-MARKER"))
        #expect(await failure(session) == .toolFailed)
        #expect(await web.count == (allow ? 1 : 0))
    }

    @Test(arguments: ["math_calculate", "time_query"])
    func invalidLocalOperationsKeepKnownIdentity(name: String) async throws {
        var settings = Self.settings(); settings.enablesCalculator = true; settings.enablesDateTime = true
        let isCalculation = name == "math_calculate"
        let provider = ToolFailureProvider(name: name, arguments: isCalculation
            ? #"{"expression":"1/0"}"# : #"{"action":"convert","date":"2026-99-01T00:00:00Z"}"#)
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key", transport: provider)
        #expect(await failure(session) == .toolFailed)
        #expect(await session.toolFailureDiagnostic() == .init(tool: isCalculation ? .calculator : .dateTime,
            reason: isCalculation ? .calculationFailed : .dateFailed))
        #expect(await provider.count == 1)
    }

    @Test func schemaRejectionKeepsToolIdentityWithoutExecuting() async throws {
        var settings = Self.settings(); settings.enablesCalculator = true
        let provider = ToolFailureProvider(name: "math_calculate", arguments: #"{"expression":42}"#)
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key", transport: provider)
        #expect(await failure(session) == .toolFailed)
        #expect(await session.toolFailureDiagnostic() == .init(tool: .calculator, reason: .invalidArguments))
        #expect(await provider.count == 1)
    }

    @Test func removedResourceIsReportedWithoutExposingContent() async throws {
        var settings = Self.settings(); settings.enablesTextResources = true
        let resources = DemoTextResourceStore()
        let item = try await resources.add(name: "private.txt", text: "PRIVATE-DIAGNOSTIC-MARKER")
        let input = try DemoResourcePageInput(resourceID: item.id)
        await resources.remove(id: item.id)
        let provider = ToolFailureProvider(name: "resource_read_text",
            arguments: String(decoding: try JSONEncoder().encode(input), as: UTF8.self))
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key",
            transport: provider, textResources: resources)
        #expect(await failure(session) == .toolFailed)
        let diagnostic = try #require(await session.toolFailureDiagnostic())
        #expect(diagnostic == .init(tool: .resourceRead, reason: .resourceUnavailable, resourceIssue: .accessDenied))
        #expect(!String(reflecting: diagnostic).contains(item.id))
        #expect(!diagnostic.message.contains("PRIVATE-DIAGNOSTIC-MARKER"))
    }

    @Test func deepSeekLimitsAreCheckedBeforeApproval() async throws {
        var settings = Self.settings(); settings.enablesWebSearch = true
        settings.search.deepSeekEnabled = true; settings.search.automaticChannel = .deepSeek
        let provider = ToolFailureProvider(name: "web_search", arguments: #"{"query":"天气","page":1,"count":5}"#)
        let approvals = ToolFailureCounter(); let web = ToolFailureWebTransport()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key", transport: provider,
            toolInteractions: .init(ask: { _ in throw BoneAskUserError.unavailable },
                authorize: { _ in await approvals.mark(); return true }), searchAPIKey: "fixture-search-key", webTransport: web)
        #expect(await failure(session) == .toolFailed)
        #expect(await session.toolFailureDiagnostic() == .init(tool: .webSearch, reason: .invalidArguments))
        #expect(await approvals.count == 0)
        #expect(await web.count == 0)
    }

    @Test func cancellationDoesNotBecomeToolFailure() async throws {
        var settings = Self.settings(); settings.enablesWebFetch = true; settings.webAllowedHosts = "example.com"
        let provider = ToolFailureProvider(name: "web_fetch", arguments: #"{"url":"https://example.com/article"}"#)
        let web = ToolFailureWebTransport()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-key", transport: provider,
            toolInteractions: .init(ask: { _ in throw CancellationError() }, authorize: { _ in throw CancellationError() }), webTransport: web)
        #expect(await failure(session) == .cancelled)
        #expect(await session.toolFailureDiagnostic() == nil)
        #expect(await web.count == 0)
    }

    @Test func arbitraryErrorAndToolIdentityNeverEnterDiagnostic() throws {
        let failure = try #require(DemoToolFailure.classify(
            NSError(domain: "PRIVATE-DIAGNOSTIC-MARKER", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "fixture-key PRIVATE-DIAGNOSTIC-MARKER"]),
            toolID: "PRIVATE-DIAGNOSTIC-MARKER"))
        #expect(failure == .init(tool: nil, reason: .unknown))
        #expect(!String(reflecting: failure).contains("PRIVATE-DIAGNOSTIC-MARKER"))
        #expect(!failure.message.contains("fixture-key"))
    }

    @Test func draftRecoveryNeverReplacesNextDraftOrRetainedTask() {
        #expect(DemoTaskRecovery.destination(for: "原问题", draft: "", retained: nil) == .draft)
        #expect(DemoTaskRecovery.destination(for: "原问题", draft: "下一条草稿", retained: nil) == .retained)
        #expect(DemoTaskRecovery.destination(for: "原问题", draft: "下一条草稿", retained: "另一条任务") == .full)
        #expect(DemoTaskRecovery.destination(for: "原问题", draft: "原问题", retained: "另一条任务") == .alreadyPresent)
        #expect(DemoTaskRecovery.destination(for: "原问题", draft: "下一条草稿", retained: "原问题") == .alreadyPresent)
    }

    private static func settings() -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .customOpenAI; settings.baseURL = "https://tool-tests.invalid"
        settings.modelID = "fixture-model"; settings.systemPrompt = ""
        settings.usesStreaming = false; settings.managesContext = false
        return settings
    }
    private func failure(_ session: DemoLiveChatSession) async -> DemoLiveChatFailure? {
        do { _ = try await session.send("查看桐乡天气"); Issue.record("Expected failure"); return nil }
        catch { return error as? DemoLiveChatFailure }
    }
}

private actor ToolFailureCounter {
    private(set) var count = 0
    func mark() { count += 1 }
}

private actor ToolFailureWebTransport: BoneWebHTTPTransport {
    private(set) var count = 0
    func send(request: URLRequest, maximumResponseBytes: Int) throws -> BoneWebHTTPResponse {
        count += 1
        return .init(url: request.url!, statusCode: 503, headers: ["Content-Type": "text/plain"],
            body: Data("fixture-key PRIVATE-DIAGNOSTIC-MARKER".utf8))
    }
}

/// Runs the real provider decoder and Conversation pipeline without any network.
private actor ToolFailureProvider: BoneInferenceHTTPTransport {
    let name: String
    let arguments: String
    private(set) var count = 0
    private(set) var requestBodies: [Data] = []
    init(name: String, arguments: String) { self.name = name; self.arguments = arguments }

    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse {
        count += 1
        if let body = request.httpBody { requestBodies.append(body) }
        let body: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "tool_calls": [
            ["id": "diagnostic-call", "type": "function", "function": ["name": name, "arguments": arguments]]
        ]], "finish_reason": "tool_calls"]]]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: body))
    }
    func sendRetryableForModels(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { try send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) throws -> BoneInferenceEventStreamResponse {
        count += 1
        if let body = request.httpBody { requestBodies.append(body) }
        func json(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        return .init(statusCode: 200, events: [
            .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"fixture","type":"message","role":"assistant","content":[],"model":"MiniMax-M3.1-Flash","usage":{"input_tokens":3,"output_tokens":0}}}"#),
            .init(event: "content_block_start", data: try json(["type": "content_block_start", "index": 0,
                "content_block": ["type": "tool_use", "id": "diagnostic-call", "name": name, "input": [:]]])),
            .init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": arguments]])),
            .init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#),
            .init(event: "message_delta", data: #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":2}}"#),
            .init(event: "message_stop", data: #"{"type":"message_stop"}"#)
        ])
    }
}
