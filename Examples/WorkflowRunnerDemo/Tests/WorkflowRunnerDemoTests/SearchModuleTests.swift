import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
import BoneAgentTesting
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct SearchModuleTests {
    @Test(arguments: DemoBrowserSearchEngine.allCases)
    func browserQueriesAreEncodedWithoutChangingTheDestination(engine: DemoBrowserSearchEngine) throws {
        let query = "Swift + C++ & 密钥? # page=2"
        let url = try engine.url(query: query)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.scheme == "https")
        #expect(parts.host == (engine == .bing ? "www.bing.com" : "www.baidu.com"))
        #expect(parts.queryItems?.count == 1)
        #expect(parts.queryItems?.first?.value == query)
        #expect(!url.absoluteString.contains("+"))
    }

    @Test func baiduWeatherQueryWorksWithOnlyTheBrowserChannelEnabled() throws {
        let configuration = DemoSearchConfiguration()
        #expect(configuration.channels() == [.browser] && !configuration.automaticEnabled)
        #expect(try configuration.checkedForSave() == configuration)
        let query = "今天桐乡温度"
        let url = try DemoSearchChannel.browser.initialURL(query: query, engine: .baidu)
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "www.baidu.com" && parts.path == "/s")
        #expect(parts.queryItems == [URLQueryItem(name: "wd", value: query)])
    }

    @Test func configurationSeparatesManualAndAutomaticChannels() throws {
        var config = DemoSearchConfiguration()
        #expect(config.channels() == [.browser])
        #expect(!config.automaticEnabled)
        config.deepSeekEnabled = true
        #expect(throws: DemoSearchError.noDefaultChannel) { try config.checkedForSave() }
        config.automaticChannel = .deepSeek
        #expect(try config.checkedForSave() == config)
        #expect(config.automaticEnabled)
        #expect(config.preferredChannel == .browser)
        config.isEnabled = false
        #expect(config.channels().isEmpty)
        #expect(try config.checkedForSave() == config)
        #expect(config.deepSeekEnabled)
        #expect(try JSONDecoder().decode(DemoSearchConfiguration.self, from: JSONEncoder().encode(config)) == config)
    }

    @Test func legacySearchJSONRetainsPreferencesAndUsesDefaultsForMissingFields() throws {
        let legacyJSON = #"{"isEnabled":true,"browserEnabled":false,"braveEnabled":true,"deepSeekEnabled":true,"preferredChannel":"deepSeek","automaticChannel":"deepSeek","browserEngine":"baidu","keepsBrowserSession":true}"#
        let data = Data(legacyJSON.utf8)
        let config = try JSONDecoder().decode(DemoSearchConfiguration.self, from: data)
        #expect(config.isEnabled && !config.browserEnabled && !config.baiduWebEnabled)
        #expect(config.braveEnabled && config.deepSeekEnabled)
        #expect(config.preferredChannel == .deepSeek && config.automaticChannel == .deepSeek)
        #expect(config.browserEngine == .baidu && config.keepsBrowserSession)
        #expect(try config.checkedForSave() == config)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let legacyObject = try JSONSerialization.jsonObject(with: data)
        #expect(try encoder.encode(config) == JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]))

        let saved = Data("{\"modelID\":\"legacy-user-model\",\"searchConfiguration\":\(legacyJSON)}".utf8)
        let settings = try JSONDecoder().decode(DemoLiveChatSettings.self, from: saved)
        #expect(settings.modelID == "legacy-user-model" && settings.search == config)
        #expect(try JSONDecoder().decode(DemoSearchConfiguration.self, from: Data("{}".utf8)) == DemoSearchConfiguration())
    }

    @Test func baiduWebIsAnOptInAutomaticChannelWithoutAnAPIKey() throws {
        var config = DemoSearchConfiguration()
        #expect(!config.baiduWebEnabled && config.automaticChannel == .brave)
        #expect(DemoSearchChannel.allCases.filter(\.requiresAPIKey) == [.brave, .deepSeek])
        #expect(DemoSearchChannel.allCases.filter(\.supportsAutomaticSearch) == [.baiduWeb, .brave, .deepSeek])
        config.baiduWebEnabled = true
        #expect(throws: DemoSearchError.noDefaultChannel) { try config.checkedForSave() }
        config.automaticChannel = .baiduWeb
        #expect(config.channels() == [.browser, .baiduWeb] && config.automaticEnabled)
        #expect(config.preferredChannel == .browser)
        #expect(try config.checkedForSave() == config)
        #expect(try JSONDecoder().decode(DemoSearchConfiguration.self, from: JSONEncoder().encode(config)) == config)
        #expect(throws: DemoSearchError.browserUnavailable) {
            try DemoSearchChannel.baiduWeb.initialURL(query: "今天桐乡温度", engine: .baidu)
        }
        config.automaticChannel = .browser
        #expect(!config.automaticEnabled)
        #expect(throws: DemoSearchError.noDefaultChannel) { try config.checkedForSave() }
    }

    @Test func baiduWebToolPlanNeedsTheServiceButDoesNotNeedSearchCredentials() {
        var settings = DemoLiveChatSettings()
        settings.search = searchConfig(.baiduWeb)
        #expect(!settings.enablesWebSearch && !DemoLabToolPlan(settings: settings).groups.contains(.webSearch))
        let plan = DemoLabToolPlan(groups: [.webSearch])
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: false,
                                  hasDeepSeekSearchKey: false).isEmpty)
        var config = settings.search; config.baiduWebEnabled = false; settings.search = config
        let requirements = plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: true,
                                              hasDeepSeekSearchKey: true)
        #expect(requirements.map(\.kind) == [.searchKey])
        #expect(requirements.first?.message.contains("启用") == true)
    }

    @Test func legacyBraveBindingsAndManualPreferencesStayCompatible() throws {
        var old = DemoLiveChatSettings(); old.enablesWebSearch = true
        #expect(old.search.braveEnabled)
        let binding = old.conversationBindingID
        let decoded = try JSONDecoder().decode(DemoLiveChatSettings.self, from: JSONEncoder().encode(old))
        #expect(decoded == old)
        var config = old.search
        config.browserEngine = .baidu; config.keepsBrowserSession = true
        old.search = config
        #expect(old.conversationBindingID == binding)
        config.deepSeekEnabled = true; config.automaticChannel = .deepSeek; old.search = config
        #expect(old.conversationBindingID != binding)
        let withoutTool = DemoLabToolPlan(groups: []).applying(to: old)
        #expect(!withoutTool.enablesWebSearch && withoutTool.search.deepSeekEnabled)
        #expect(withoutTool.search.automaticChannel == .deepSeek)
    }

    @Test func readinessUsesTheSelectedProvidersCredential() throws {
        var settings = DemoLiveChatSettings()
        var config = settings.search
        config.deepSeekEnabled = true; config.automaticChannel = .deepSeek
        settings.search = config
        let plan = DemoLabToolPlan(groups: [.webSearch])
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: true).map(\.kind) == [.searchKey])
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: false, hasDeepSeekSearchKey: true).isEmpty)
        config.isEnabled = false; settings.search = config
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: true, hasDeepSeekSearchKey: true).map(\.kind) == [.searchKey])
    }

    @Test func disabledRouterMakesNoRequestAndDoesNotUseAnotherChannel() async throws {
        var config = DemoSearchConfiguration(); config.braveEnabled = true; config.isEnabled = false
        let probe = SearchHTTPProbe()
        let router = DemoSearchRouter(configuration: config, apiKey: "test-key", transport: probe)
        await #expect(throws: DemoSearchError.disabled) { try await router.search(BoneWebSearchInput(query: "hello")) }
        #expect(await probe.requests.isEmpty)
        config.isEnabled = true
        let manual = DemoSearchRouter(configuration: config, channel: .browser, apiKey: "test-key", transport: probe)
        await #expect(throws: DemoSearchError.disabled) { try await manual.search(BoneWebSearchInput(query: "hello")) }
        #expect(await probe.requests.isEmpty)
    }

    @Test func baiduWebRouterUsesOnlyTheInjectedHandlerWithoutAKey() async throws {
        var config = DemoSearchConfiguration(); config.baiduWebEnabled = true; config.automaticChannel = .baiduWeb
        let browser = SearchBrowserProbe()
        let http = SearchHTTPProbe()
        let handler: DemoBrowserSearchHandler = { try await browser.search($0) }
        let router = DemoSearchRouter(configuration: config, apiKey: "", transport: http, browserSearch: handler)
        let input = try BoneWebSearchInput(query: "今天桐乡温度", count: 1)
        let output = try await router.search(input)
        #expect(output.provider == "baidu-web" && output.results.count == 1 && output.nextPage == nil)
        #expect(output.contentTrust == .untrustedData)
        #expect(await browser.inputs == [input])
        #expect(await http.requests.isEmpty)
    }

    @Test func baiduWebRejectsPaginationDisabledAndManualRoutesBeforeDispatch() async throws {
        var config = searchConfig(.baiduWeb)
        let browser = SearchBrowserProbe()
        let http = SearchHTTPProbe()
        let handler: DemoBrowserSearchHandler = { try await browser.search($0) }
        let input = try BoneWebSearchInput(query: "今天桐乡温度")
        let paged = DemoSearchRouter(configuration: config, apiKey: "", transport: http, browserSearch: handler)
        await #expect(throws: DemoBrowserSearchError.unsupportedPage) {
            try await paged.search(BoneWebSearchInput(query: "今天桐乡温度", page: 1))
        }
        config.baiduWebEnabled = false
        let disabled = DemoSearchRouter(configuration: config, apiKey: "", transport: http, browserSearch: handler)
        await #expect(throws: DemoSearchError.disabled) { try await disabled.search(input) }
        config.baiduWebEnabled = true; config.isEnabled = false
        let allDisabled = DemoSearchRouter(configuration: config, apiKey: "", transport: http, browserSearch: handler)
        await #expect(throws: DemoSearchError.disabled) { try await allDisabled.search(input) }
        config.isEnabled = true
        let manual = DemoSearchRouter(configuration: config, channel: .browser, apiKey: "", transport: http, browserSearch: handler)
        await #expect(throws: DemoSearchError.disabled) { try await manual.search(input) }
        #expect(await browser.inputs.isEmpty)
        #expect(await http.requests.isEmpty)
    }

    @Test func baiduWebWithoutAHandlerFailsWithoutFallingBackToAnAPI() async throws {
        let http = SearchHTTPProbe()
        let secret = "unit-test-key-must-not-be-used"
        let router = DemoSearchRouter(configuration: searchConfig(.baiduWeb), apiKey: secret, transport: http)
        await #expect(throws: DemoBrowserSearchError.unavailable) {
            try await router.search(BoneWebSearchInput(query: "今天桐乡温度"))
        }
        #expect(await http.requests.isEmpty)
        #expect(!String(describing: router).contains(secret) && !String(reflecting: router).contains(secret))
    }

    @Test func baiduWebVerificationStopsWithoutRetryOrAPIFallback() async throws {
        let browser = SearchBrowserProbe(failure: .verificationRequired)
        let http = SearchHTTPProbe()
        let handler: DemoBrowserSearchHandler = { try await browser.search($0) }
        let router = DemoSearchRouter(configuration: searchConfig(.baiduWeb), apiKey: "", transport: http, browserSearch: handler)
        await #expect(throws: DemoBrowserSearchError.verificationRequired) {
            try await router.search(BoneWebSearchInput(query: "今天桐乡温度"))
        }
        #expect(await browser.inputs.count == 1)
        #expect(await http.requests.isEmpty)
    }

    @Test(arguments: [DemoSearchChannel.brave, .deepSeek])
    func apiRoutesStillRequireTheirOwnKeyAndNeverUseTheBrowser(channel: DemoSearchChannel) async throws {
        let browser = SearchBrowserProbe()
        let http = SearchHTTPProbe()
        let handler: DemoBrowserSearchHandler = { try await browser.search($0) }
        var config = searchConfig(channel); config.baiduWebEnabled = true
        let router = DemoSearchRouter(configuration: config, apiKey: " \n", transport: http, browserSearch: handler)
        await #expect(throws: DemoSearchError.missingKey) { try await router.search(BoneWebSearchInput(query: "hello")) }
        #expect(await browser.inputs.isEmpty)
        #expect(await http.requests.isEmpty)
    }

    @Test(arguments: [DemoSearchChannel.brave, .deepSeek])
    func apiRouteSendsOnlyItsCredentialToItsOwnEndpoint(channel: DemoSearchChannel) async throws {
        let probe = SearchHTTPProbe()
        let config = searchConfig(channel)
        let secret = "credential-\(channel.rawValue)-unit-test-only"
        let router = DemoSearchRouter(configuration: config, channel: channel, apiKey: secret, transport: probe)
        let output = try await router.search(BoneWebSearchInput(query: "Swift 并发 + actor", count: 1))
        #expect(output.provider == (channel == .deepSeek ? "deepseek" : "brave"))
        #expect(output.results.count == 1 && output.contentTrust == .untrustedData)
        let requests = await probe.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        if channel == .deepSeek {
            #expect(request.url == DemoDeepSeekSearchClient.endpoint)
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + secret)
            #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == nil)
            let body = try JSONDecoder().decode(SearchRequestBody.self, from: #require(request.httpBody))
            #expect(body.query == "Swift 并发 + actor" && body.count == 1 && !body.need_content)
            #expect(output.nextPage == nil)
        } else {
            #expect(request.url?.host == "api.search.brave.com")
            #expect(request.httpMethod == "GET" && request.httpBody == nil)
            #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == secret)
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        }
        #expect(!String(decoding: try JSONEncoder().encode(output), as: UTF8.self).contains(secret))
        #expect(!String(describing: router).contains(secret))
        #expect(!String(reflecting: router).contains(secret))
    }

    @Test func deepSeekRejectsUnsupportedInputsBeforeDispatch() async throws {
        let probe = SearchHTTPProbe()
        let client = try DemoDeepSeekSearchClient(apiKey: "test-key", transport: probe)
        await #expect(throws: DemoSearchError.unsupportedPage) { try await client.search(input: BoneWebSearchInput(query: "hello", page: 1)) }
        await #expect(throws: DemoSearchError.invalidQuery) { try await client.search(input: BoneWebSearchInput(query: String(repeating: "字", count: 129))) }
        #expect(await probe.requests.isEmpty)
    }

    @Test(arguments: [401, 402, 429, 500])
    func deepSeekFailuresDoNotRetryOrExposeResponse(status: Int) async throws {
        let probe = SearchHTTPProbe(status: status)
        let router = DemoSearchRouter(configuration: searchConfig(.deepSeek), apiKey: "test-credential", transport: probe)
        await #expect(throws: BoneWebError.httpFailure) { try await router.search(BoneWebSearchInput(query: "hello")) }
        #expect(await probe.requests.count == 1)
    }

    @Test func cancellationBeforeSearchNeverDispatches() async throws {
        let probe = SearchHTTPProbe()
        let router = DemoSearchRouter(configuration: searchConfig(.deepSeek), apiKey: "test-credential", transport: probe)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await router.search(BoneWebSearchInput(query: "hello"))
        }
        do { _ = try await operation.value; Issue.record("Cancelled search completed") }
        catch is CancellationError {}
        #expect(await probe.requests.isEmpty)
    }

    @Test func deepSeekSearchExecutesThroughTheActualAgentToolPipeline() async throws {
        var settings = DemoLiveChatSettings()
        settings.search = searchConfig(.deepSeek)
        settings.enablesWebSearch = true
        let probe = SearchHTTPProbe()
        let authorization = SearchAuthorizationProbe()
        let handlers = DemoToolInteractionHandlers(ask: { _ in throw CancellationError() }, authorize: { request in
            await authorization.record(request.detail)
            return true
        })
        let call = BoneInferenceToolCall(id: "search-call", toolID: "web.search",
            arguments: try JSONEncoder().encode(BoneWebSearchInput(query: "Swift", count: 1)))
        let engine = BoneScriptedInferenceEngine(script: [
            .assistantTurn(turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls,
                           usage: nil, refusal: nil, providerContinuation: nil),
            .finish(.init(text: "来源已读取"))
        ])
        let effects = DemoToolEffectStore()
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil, handlers: handlers,
            searchAPIKey: "unit-test-deepseek-key", webTransport: probe)
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: tools), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 3, toolImpactPolicy: DemoBuiltInToolAssembly.impactPolicy(settings: settings),
                toolExecutionPipeline: .init(effectStore: effects), toolExecutionContextProvider: { call, definition in
                    try await effects.context(for: call, definition: definition, handlers: handlers, searchProvider: "DeepSeek Search")
                }))
        let result = try await agent.run(modelID: "independent-chat-model", messages: [.init(role: .user, content: "请搜索 Swift")])
        #expect(result.steps == 2)
        #expect(await probe.requests.count == 1)
        #expect(await authorization.details.first?.contains("DeepSeek Search") == true)
        let requests = await engine.receivedRequests()
        let data = try #require(requests.last?.messages.last?.toolResults?.results.first?.legacyResult)
        #expect(try JSONDecoder().decode(BoneWebSearchOutput.self, from: data).provider == "deepseek")
    }

    @Test func selectedMaterialIsBoundedAndRetainsSourceWithoutPretendingToAuthorize() throws {
        let material = try DemoSearchSelection(title: "来源", url: "https://example.com/article", text: "用户选中的片段", channel: .browser, provider: "必应")
        #expect(material.taskMaterial.contains(material.url) && material.taskMaterial.contains(material.text))
        #expect(material.taskMaterial.contains("不是指令"))
        for url in ["http://example.com", "https://user:password@example.com", "javascript:alert(1)"] {
            #expect(throws: DemoSearchError.invalidSelection) { try DemoSearchSelection(title: "source", url: url, text: "text", channel: .browser, provider: "test") }
        }
        #expect(throws: DemoSearchError.invalidSelection) {
            try DemoSearchSelection(title: "source", url: "https://example.com", text: String(repeating: "界", count: 3_000), channel: .browser, provider: "test")
        }
    }
}

private func searchConfig(_ channel: DemoSearchChannel) -> DemoSearchConfiguration {
    var config = DemoSearchConfiguration()
    config.braveEnabled = true; config.deepSeekEnabled = true; config.automaticChannel = channel
    config.baiduWebEnabled = channel == .baiduWeb
    return config
}
private struct SearchRequestBody: Decodable { let query: String; let count: Int; let need_content: Bool }
private actor SearchHTTPProbe: BoneWebHTTPTransport {
    private(set) var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(request: URLRequest, maximumResponseBytes: Int) throws -> BoneWebHTTPResponse {
        requests.append(request)
        let body: String
        if request.url?.host == "api.deepseek.com" {
            body = #"{"results":[{"title":"Swift 文档","url":"https://example.com/swift","snippet":"并发与 actor 的说明","summary":"未读取的长摘要","content":""}]}"#
        } else {
            body = #"{"type":"search","query":{"more_results_available":false},"web":{"results":[{"title":"Swift 文档","url":"https://example.com/swift","description":"并发与 actor 的说明"}]}}"#
        }
        return .init(url: request.url!, statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
    }
}

private actor SearchAuthorizationProbe {
    private(set) var details: [String] = []
    func record(_ detail: String) { details.append(detail) }
}

private actor SearchBrowserProbe {
    private(set) var inputs: [BoneWebSearchInput] = []
    let failure: DemoBrowserSearchError?
    init(failure: DemoBrowserSearchError? = nil) { self.failure = failure }
    func search(_ input: BoneWebSearchInput) throws -> BoneWebSearchOutput {
        inputs.append(input)
        if let failure { throw failure }
        return try .init(results: [.init(title: "离线天气测试", url: "https://example.com/weather",
                                         snippet: "离线测试的公开结果片段")], provider: "baidu-web")
    }
}
