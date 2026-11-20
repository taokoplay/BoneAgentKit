import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct WeatherSearchSimulationTests {
    static let query = "今天桐乡温度"
    static let simulatedAnswer = "【离线模拟，非真实天气】桐乡气温为 23℃。来源：https://weather.example.org/tongxiang"

    @Test func currentSevenToolConfigurationDoesNotRegisterSearch() throws {
        let settings = Self.settings()
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: DemoTextResourceStore(),
            handlers: .unavailable, searchAPIKey: "")
        #expect(tools.count == 7)
        #expect(!tools.contains { $0.definition.id == "web.search" })
        #expect(settings.webHostNames == ["www.baidu.com"])
        #expect(!settings.search.braveEnabled && !settings.search.deepSeekEnabled)
    }

    @Test func miniMaxWeatherQueryUsesSearchAPIAndReturnsItsResultWithOneConfirmation() async throws {
        var settings = Self.settings()
        settings.enablesWebSearch = true
        settings.search.deepSeekEnabled = true
        settings.search.automaticChannel = .deepSeek
        let model = WeatherModelFixture(steps: [
            .call("time_query", #"{"action":"now","timeZoneID":"Asia/Shanghai"}"#),
            .call("web_search", #"{"query":"今天桐乡温度","count":1,"page":0}"#),
            .reply(Self.simulatedAnswer)
        ])
        let approvals = WeatherApprovalProbe(); let network = WeatherWebFixture()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, searchAPIKey: "fixture-search-key", webTransport: network)
        let reply = try await session.send(Self.query)
        #expect(reply.text == Self.simulatedAnswer && reply.steps == 3 && reply.toolCalls == 2)
        #expect(await approvals.count == 1)
        #expect(await network.requests.count == 1)
        let request = try #require(await network.requests.first)
        #expect(request.url == DemoDeepSeekSearchClient.endpoint && request.httpMethod == "POST")
        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["query"] as? String == Self.query)
        let requests = await model.requests
        #expect(requests.count == 3)
        let first = try #require(JSONSerialization.jsonObject(with: requests[0]) as? [String: Any])
        let messages = try #require(first["messages"] as? [[String: Any]])
        #expect(messages.last?["content"] as? String == Self.query)
        let last = String(decoding: requests[2], as: UTF8.self)
        #expect(last.contains("离线模拟") && last.contains("23") && last.contains("weather.example.org"))
        #expect(await session.failureDiagnostic() == nil)
    }

    @Test(arguments: [true, false])
    func redirectAndMalformedPageHaveDifferentReasonsForWeatherPrompt(redirect: Bool) async throws {
        let model = WeatherModelFixture(steps: [.call("web_fetch", #"{"url":"https://www.baidu.com/"}"#)])
        let approvals = WeatherApprovalProbe(); let network = WeatherWebFixture(redirect: redirect, malformedPage: !redirect)
        let session = try await DemoLiveChatSession.make(settings: Self.settings(), apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, webTransport: network)
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send(Self.query) }
        let failure = try #require(await session.toolFailureDiagnostic())
        #expect(failure.tool == .webFetch && failure.reason == (redirect ? .redirectNotAllowed : .invalidResponse))
        #expect(await approvals.count == 1)
        #expect(await network.requests.count == 1)
        let record = try #require(await session.failureDiagnostic())
        #expect(record.code == .toolFailure && record.networkConfirmations == 1)
    }

    @Test(arguments: ["https://www.baidu.com/s?wd=今天桐乡温度", "https://www.baidu.com/?word=test", "https://www.bing.com/search?q=test"])
    func searchResultsAreRoutedAwayFromStaticReaderBeforeApproval(url: String) async throws {
        var settings = Self.settings(); settings.webAllowedHosts = "www.baidu.com www.bing.com"
        let input = String(decoding: try JSONEncoder().encode(BoneWebFetchInput(url: url)), as: UTF8.self)
        let model = WeatherModelFixture(steps: [.call("web_fetch", input)])
        let approvals = WeatherApprovalProbe(); let network = WeatherWebFixture()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, webTransport: network)
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send(Self.query) }
        let failure = try #require(await session.toolFailureDiagnostic())
        #expect(failure.reason == .manualSearchRequired && failure.offersSearch)
        #expect(await approvals.count == 0)
        #expect(await network.requests.isEmpty)
    }

    @Test func normalStaticPagesRetainTheOriginalHostPolicy() throws {
        let policy = try BoneWebHostPolicy(allowedHosts: ["www.baidu.com", "example.com"])
        #expect(try DemoWebFetchNavigationPolicy.validate(url: "https://www.baidu.com/about", policy: policy).host == "www.baidu.com")
        #expect(try DemoWebFetchNavigationPolicy.validate(url: "https://example.com/search?q=test", policy: policy).host == "example.com")
        #expect(throws: BoneWebError.hostNotAllowed) {
            try DemoWebFetchNavigationPolicy.validate(url: "https://another.example.org/article", policy: policy)
        }
    }

    @Test func baiduWebResultsReachMiniMaxWithoutSearchKeyAndConfirmOnlyOnce() async throws {
        var settings = Self.settings()
        settings.enablesWebSearch = true
        settings.search.baiduWebEnabled = true; settings.search.automaticChannel = .baiduWeb
        let answer = "【离线模拟，非真实天气】桐乡23℃；来源：百度公开结果。"
        let model = WeatherModelFixture(steps: [
            .call("web_search", #"{"query":"今天桐乡温度","count":1,"page":0}"#),
            .call("web_search", #"{"query":"今天桐乡温度","count":1,"page":0}"#), .reply(answer)
        ])
        let browser = WeatherBrowserProbe(); let approvals = WeatherApprovalProbe(); let api = WeatherWebFixture()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, webTransport: api, browserSearch: browser.handler)
        let reply = try await session.send(Self.query)
        #expect(reply.text == answer && reply.steps == 3 && reply.toolCalls == 2)
        #expect(await browser.queries == [Self.query, Self.query])
        #expect(await api.requests.isEmpty)
        #expect(await approvals.count == 1)
        let confirmation = try #require(await approvals.details.first)
        #expect(confirmation.contains("无需搜索 API Key") && confirmation.contains("当前模型"))
        let requests = await model.requests
        let first = try #require(JSONSerialization.jsonObject(with: requests[0]) as? [String: Any])
        #expect((first["system"] as? String)?.contains("page 必须为 0") == true)
        let last = String(decoding: requests[2], as: UTF8.self)
        #expect(last.contains("baidu-web") && last.contains("23") && last.contains("www.baidu.com"))
        #expect(last.contains("参考数据") && last.contains("网页读取时间"))
    }

    @Test func deniedBaiduConsentDoesNotStartBrowser() async throws {
        var settings = Self.settings(); settings.enablesWebSearch = true
        settings.search.baiduWebEnabled = true; settings.search.automaticChannel = .baiduWeb
        let model = WeatherModelFixture(steps: [.call("web_search", #"{"query":"今天桐乡温度","page":0}"#)])
        let browser = WeatherBrowserProbe(); let approvals = WeatherApprovalProbe(approved: false)
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, browserSearch: browser.handler)
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send(Self.query) }
        #expect(await browser.queries.isEmpty)
        #expect(await approvals.count == 1)
        #expect(await session.toolFailureDiagnostic()?.reason == .notAuthorized)
    }

    @Test(arguments: [DemoBrowserSearchError.verificationRequired, .timedOut, .navigationChanged])
    func baiduFailuresKeepCauseAndDoNotRetry(error: DemoBrowserSearchError) async throws {
        var settings = Self.settings(); settings.enablesWebSearch = true
        settings.search.baiduWebEnabled = true; settings.search.automaticChannel = .baiduWeb
        let model = WeatherModelFixture(steps: [.call("web_search", #"{"query":"今天桐乡温度","page":0}"#)])
        let browser = WeatherBrowserProbe(error: error); let approvals = WeatherApprovalProbe()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, browserSearch: browser.handler)
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send(Self.query) }
        let expected = DemoToolFailure.classify(error, toolID: "web.search")
        #expect(await session.toolFailureDiagnostic()?.reason == expected?.reason)
        await #expect(throws: DemoLiveChatFailure.toolFailed) { try await session.send(Self.query) }
        #expect(await browser.queries.count == 1)
        #expect(await model.requests.count == 1)
    }

    @Test func cancellingBaiduReadCannotPublishOrReplayResult() async throws {
        var settings = Self.settings(); settings.enablesWebSearch = true
        settings.search.baiduWebEnabled = true; settings.search.automaticChannel = .baiduWeb
        let model = WeatherModelFixture(steps: [.call("web_search", #"{"query":"今天桐乡温度","page":0}"#)])
        let browser = WeatherBrowserProbe(waits: true); let approvals = WeatherApprovalProbe()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "fixture-model-key", transport: model,
            toolInteractions: approvals.handlers, browserSearch: browser.handler)
        let sending = Task { try await session.send(Self.query) }
        await browser.waitForStart()
        sending.cancel()
        await #expect(throws: DemoLiveChatFailure.cancelled) { try await sending.value }
        await #expect(throws: DemoLiveChatFailure.cancelled) { try await session.send(Self.query) }
        #expect(await browser.queries.count == 1)
        #expect(await model.requests.count == 1)
    }

    private static func settings() -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .init(rawValue: "MiniMax"); settings.modelID = "MiniMax-M3.1-Flash"
        settings.baseURL = "https://weather-fixture.invalid/anthropic"
        settings.systemPrompt = ""; settings.usesStreaming = true; settings.managesContext = false
        settings.enablesCalculator = true; settings.enablesDateTime = true
        settings.enablesTextResources = true; settings.enablesAskUser = true
        settings.enablesWebFetch = true; settings.webAllowedHosts = "www.baidu.com"
        settings.enablesWebSearch = false; settings.search = DemoSearchConfiguration()
        return settings
    }
}

private actor WeatherApprovalProbe {
    private(set) var count = 0
    private(set) var details: [String] = []
    let approved: Bool
    init(approved: Bool = true) { self.approved = approved }
    nonisolated var handlers: DemoToolInteractionHandlers {
        .init(ask: { _ in throw CancellationError() }, authorize: { request in await self.approve(request.detail) })
    }
    private func approve(_ detail: String) -> Bool { count += 1; details.append(detail); return approved }
}

private actor WeatherWebFixture: BoneWebHTTPTransport {
    let redirect: Bool
    let malformedPage: Bool
    private(set) var requests: [URLRequest] = []
    init(redirect: Bool = false, malformedPage: Bool = false) { self.redirect = redirect; self.malformedPage = malformedPage }
    func send(request: URLRequest, maximumResponseBytes: Int) throws -> BoneWebHTTPResponse {
        requests.append(request)
        let url = request.url!
        if redirect {
            return .init(url: url, statusCode: 302, headers: ["Location": "https://www.baidu.com/redirected"], body: Data())
        }
        if malformedPage {
            return .init(url: url, statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data([0xFF, 0xFE]))
        }
        guard url == DemoDeepSeekSearchClient.endpoint else { throw BoneWebError.requestFailed }
        return .init(url: url, statusCode: 200, headers: ["Content-Type": "application/json"],
            body: Data(#"{"results":[{"title":"离线模拟天气","url":"https://weather.example.org/tongxiang","snippet":"【离线模拟，非真实天气】桐乡气温23℃。"}]}"#.utf8))
    }
}

private actor WeatherModelFixture: BoneInferenceHTTPTransport {
    enum Step: Sendable { case call(String, String), reply(String) }
    private var steps: [Step]
    private(set) var requests: [Data] = []
    init(steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { throw BoneInferenceTransportError.invalidResponse }
    func sendRetryableForModels(_ request: URLRequest) throws -> BoneInferenceHTTPResponse { throw BoneInferenceTransportError.invalidResponse }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) throws -> BoneInferenceEventStreamResponse {
        guard !steps.isEmpty, let body = request.httpBody else { throw BoneInferenceTransportError.invalidResponse }
        requests.append(body)
        let step = steps.removeFirst()
        func json(_ value: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
        }
        var events: [BoneInferenceEventStreamEvent] = [
            .init(event: "message_start", data: #"{"type":"message_start","message":{"id":"weather-fixture","type":"message","role":"assistant","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}"#)
        ]
        let reason: String
        switch step {
        case .call(let name, let arguments):
            reason = "tool_use"
            events.append(.init(event: "content_block_start", data: try json(["type": "content_block_start", "index": 0,
                "content_block": ["type": "tool_use", "id": "weather-\(requests.count)", "name": name, "input": [:]]])))
            events.append(.init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0,
                "delta": ["type": "input_json_delta", "partial_json": arguments]])))
        case .reply(let text):
            reason = "end_turn"
            events.append(.init(event: "content_block_start", data: #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#))
            events.append(.init(event: "content_block_delta", data: try json(["type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": text]])))
        }
        events.append(.init(event: "content_block_stop", data: #"{"type":"content_block_stop","index":0}"#))
        events.append(.init(event: "message_delta", data: try json(["type": "message_delta", "delta": ["stop_reason": reason], "usage": ["output_tokens": 2]])))
        events.append(.init(event: "message_stop", data: #"{"type":"message_stop"}"#))
        return .init(statusCode: 200, events: events)
    }
}

private actor WeatherBrowserProbe {
    let error: DemoBrowserSearchError?
    let waits: Bool
    private(set) var queries: [String] = []
    private var started: CheckedContinuation<Void, Never>?
    init(error: DemoBrowserSearchError? = nil, waits: Bool = false) { self.error = error; self.waits = waits }
    nonisolated var handler: DemoBrowserSearchHandler { { input in try await self.read(input) } }
    func waitForStart() async {
        if !queries.isEmpty { return }
        await withCheckedContinuation { started = $0 }
    }
    private func read(_ input: BoneWebSearchInput) async throws -> BoneWebSearchOutput {
        queries.append(input.query); started?.resume(); started = nil
        if waits { try await Task.sleep(for: .seconds(60)) }
        try Task.checkCancellation()
        if let error { throw error }
        return try DemoBrowserSearchSnapshot(query: input.query,
            pageURL: DemoBrowserSearchEngine.baidu.url(query: input.query).absoluteString,
            title: "离线百度结果", text: "【离线模拟，非真实天气】桐乡23℃").output()
    }
}
