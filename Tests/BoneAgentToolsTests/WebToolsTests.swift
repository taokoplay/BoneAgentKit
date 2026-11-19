import Foundation
import XCTest
import BoneAgentKit
@testable import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private struct WebScope: BoneAgentToolContext { let permitted: Bool }

private actor WebFakeTransport: BoneWebHTTPTransport {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> BoneWebHTTPResponse
    private let handler: Handler
    private var requests: [(URLRequest, Int)] = []
    init(_ handler: @escaping Handler) { self.handler = handler }
    func send(request: URLRequest, maximumResponseBytes: Int) async throws -> BoneWebHTTPResponse {
        requests.append((request, maximumResponseBytes))
        return try await handler(request, maximumResponseBytes)
    }
    func snapshot() -> [(URLRequest, Int)] { requests }
}

private func webResponse(_ request: URLRequest, body: String, contentType: String = "text/html",
                         status: Int = 200, finalURL: URL? = nil) -> BoneWebHTTPResponse {
    .init(url: finalURL ?? request.url!, statusCode: status, headers: ["Content-Type": contentType], body: Data(body.utf8))
}

private func assertWebError(_ expected: BoneWebError, file: StaticString = #filePath, line: UInt = #line,
                            _ operation: () async throws -> Void) async {
    do { try await operation(); XCTFail("Expected a fixed web error", file: file, line: line) }
    catch { XCTAssertEqual(error as? BoneWebError, expected, file: file, line: line) }
}

private actor WebSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() { signalled = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

final class WebToolsTests: XCTestCase, @unchecked Sendable {
    func testSchemasIdentityDefaultsAndHonestImpact() throws {
        let fetch = try BoneWebFetchTool<WebScope>.definition.validatedForModelExposure()
        let search = try BoneWebSearchTool<WebScope>.definition.validatedForModelExposure()
        XCTAssertEqual(fetch.id, "web.fetch")
        XCTAssertEqual(fetch.wireName, "web_fetch")
        XCTAssertEqual(search.id, "web.search")
        XCTAssertEqual(search.wireName, "web_search")
        for definition in [fetch, search] {
            let impact = try definition.requiredImpact()
            XCTAssertEqual(impact.externalTransmission, .arbitraryNetwork)
            XCTAssertTrue(impact.requiresHostAuthorization)
            XCTAssertFalse(impact.isLocalReadOnly)
            XCTAssertThrowsError(try BoneToolImpactPolicy(maximumAllowed: .ordinaryPublicRead).authorize(impact))
        }
        XCTAssertEqual(fetch.impact?.economic, BoneToolEconomicImpact.none)
        XCTAssertEqual(search.impact?.economic, .metered)
        let fetchSchema = try XCTUnwrap(fetch.inputSchema)
        let searchSchema = try XCTUnwrap(search.inputSchema)
        let fetchJSON = Data(#"{"url":"https://example.com/page"}"#.utf8)
        let searchJSON = Data(#"{"query":"swift"}"#.utf8)
        try BoneToolSchemaValidator.validate(arguments: fetchJSON, against: fetchSchema)
        try BoneToolSchemaValidator.validate(arguments: searchJSON, against: searchSchema)
        XCTAssertEqual(try JSONDecoder().decode(BoneWebFetchInput.self, from: fetchJSON).maximumTextBytes, 16_384)
        let defaults = try JSONDecoder().decode(BoneWebSearchInput.self, from: searchJSON)
        XCTAssertEqual(defaults.count, 5)
        XCTAssertEqual(defaults.page, 0)
        for invalid in [#"{"query":"x","count":0}"#, #"{"query":"x","page":-1}"#,
                        #"{"query":"x","page":10}"#, #"{"query":"x","apiKey":"unexpected"}"#] {
            XCTAssertThrowsError(try BoneToolSchemaValidator.validate(arguments: Data(invalid.utf8), against: searchSchema))
        }
    }

    func testStrictInputOutputAndDecodingValidation() throws {
        XCTAssertThrowsError(try BoneWebFetchInput(url: "https://example.com", maximumTextBytes: 0))
        XCTAssertThrowsError(try BoneWebFetchInput(url: "https://example.com", maximumTextBytes: 32_769))
        for count in [0, 11] { XCTAssertThrowsError(try BoneWebSearchInput(query: "x", count: count)) }
        for page in [-1, 10] { XCTAssertThrowsError(try BoneWebSearchInput(query: "x", page: page)) }
        for query in [" ", "x\u{0}", String(repeating: "文", count: 683)] {
            XCTAssertThrowsError(try BoneWebSearchInput(query: query))
        }
        for invalid in [#"{"query":"x","page":-1}"#, #"{"query":"x","count":null}"#,
                        #"{"query":"x","apiKey":"secret-payload"}"#, #"{"query":"x","count":"secret-payload"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(BoneWebSearchInput.self, from: Data(invalid.utf8))) {
                XCTAssertEqual($0 as? BoneWebError, .invalidInput)
                XCTAssertFalse(String(describing: $0).contains("secret-payload"))
            }
        }
        XCTAssertThrowsError(try BoneWebSearchResult(title: "x", url: "https://127.0.0.1", snippet: ""))
        XCTAssertThrowsError(try BoneWebSearchResult(title: String(repeating: "x", count: 513), url: "https://example.com", snippet: ""))
        XCTAssertThrowsError(try BoneWebSearchResult(title: "x", url: "https://example.com", snippet: String(repeating: "x", count: 2_049)))
        XCTAssertThrowsError(try BoneWebSearchOutput(results: [], provider: "", nextPage: 10))
        XCTAssertThrowsError(try BoneWebSearchOutput(results: [], provider: "custom", searchedAt: Date(timeIntervalSince1970: .infinity)))
        XCTAssertThrowsError(try BoneWebFetchOutput(url: "https://example.com", finalURL: "http://example.com", title: "", text: "", truncated: false))
        XCTAssertThrowsError(try BoneWebFetchOutput(url: "https://example.com", finalURL: "https://example.com", title: "", text: String(repeating: "x", count: 32_769), truncated: false))
        let output = try BoneWebFetchOutput(url: "https://example.com", finalURL: "https://example.com", title: "", text: "data", truncated: false)
        let encoded = try JSONEncoder().encode(output)
        XCTAssertEqual(try JSONDecoder().decode(BoneWebFetchOutput.self, from: encoded), output)
        let tampered = String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "untrusted_data", with: "trusted")
        XCTAssertThrowsError(try JSONDecoder().decode(BoneWebFetchOutput.self, from: Data(tampered.utf8)))
    }

    func testMandatoryExactAllowlistAndURLRestrictions() throws {
        for hosts in [[], ["*.example.com"], ["localhost"], ["127.0.0.1"], ["2130706433"],
                      ["0x7f.0x0.0x0.0x1"], ["machine.local"], ["machine.home.arpa"], ["example.com."]] {
            XCTAssertThrowsError(try BoneWebHostPolicy(allowedHosts: hosts))
        }
        let policy = try BoneWebHostPolicy(allowedHosts: ["EXAMPLE.com"])
        XCTAssertNoThrow(try policy.validate(url: "https://example.com:443/a?q=1"))
        for url in ["http://example.com", "https://user:pass@example.com", "https://@example.com",
                    "https://example.com/#fragment", "https://example.com/#", "https://example.com:444",
                    "https://127.0.0.1", "https://[::1]", "https://localhost", "https://machine.internal",
                    "https://example.com.", "https://sub.example.com", "https://other.example.com",
                    "https://example.com/\n", "https://example.com.evil.com"] {
            XCTAssertThrowsError(try policy.validate(url: url))
        }
        XCTAssertThrowsError(try BoneBraveSearchClient(apiKey: "key", policy: policy))
        let bravePolicy = try BoneWebHostPolicy(allowedHosts: ["api.search.brave.com"])
        XCTAssertThrowsError(try BoneBraveSearchClient(apiKey: "", policy: bravePolicy))
        XCTAssertThrowsError(try BoneBraveSearchClient(apiKey: "key\n", policy: bravePolicy))
        XCTAssertThrowsError(try BoneBraveSearchClient(apiKey: "key", policy: bravePolicy, maximumResponseBytes: 1_048_577))
        XCTAssertThrowsError(try BoneWebFetchHTTPClient(policy: policy, maximumResponseBytes: 2_097_153))
        XCTAssertThrowsError(try BoneWebFetchHTTPClient(policy: policy, maximumOutputBytes: 32_769))
    }

    func testNoAutomaticNetworkAndContextAuthorizationBeforeClient() async throws {
        let transport = WebFakeTransport { request, _ in
            if request.url?.host == "api.search.brave.com" {
                return webResponse(request, body: #"{"type":"search","web":{"results":[]}}"#, contentType: "application/json")
            }
            return webResponse(request, body: "<p>public</p>")
        }
        let policy = try BoneWebHostPolicy(allowedHosts: ["example.com", "api.search.brave.com"])
        let fetchClient = try BoneWebFetchHTTPClient(policy: policy, transport: transport)
        let searchClient = try BoneBraveSearchClient(apiKey: "offline-key", policy: policy, transport: transport)
        let fetch = BoneWebFetchTool<WebScope>(client: fetchClient) { _, context in
            guard context.permitted else { throw BoneWebError.scopeDenied }
        }
        let search = BoneWebSearchTool<WebScope>(client: searchClient) { _, context in
            guard context.permitted else { throw BoneWebError.scopeDenied }
        }
        _ = BoneWebFetchTool<WebScope>.definition
        _ = BoneWebSearchTool<WebScope>.definition
        let before = await transport.snapshot()
        XCTAssertTrue(before.isEmpty)
        let fetchInput = try BoneWebFetchInput(url: "https://example.com/page")
        let searchInput = try BoneWebSearchInput(query: "swift")
        await assertWebError(.scopeDenied) { _ = try await fetch.execute(input: fetchInput, context: .init(permitted: false)) }
        await assertWebError(.scopeDenied) { _ = try await search.execute(input: searchInput, context: .init(permitted: false)) }
        let denied = await transport.snapshot()
        XCTAssertTrue(denied.isEmpty)
        _ = try await fetch.execute(input: fetchInput, context: .init(permitted: true))
        _ = try await search.execute(input: searchInput, context: .init(permitted: true))
        let allowed = await transport.snapshot()
        XCTAssertEqual(allowed.count, 2)
    }

    func testStaticHTMLSourcesEntityDecodingAndRemoval() async throws {
        let html = """
        <html><head><title>A &amp; B &#x1F642;</title><style>secret-style</style></head><body>
        <nav>secret-nav<nav>nested-nav</nav>still-nav</nav><!-- secret-comment -->
        <script>if (a < b) { window.secret = '<fake>'; }</script>
        <main><h1>Hello</h1><p data-x='>'>world &amp; &#128578; &lt;data&gt; &copy; &unknown;</p></main>
        <footer>secret-footer</footer><noscript>secret-noscript</noscript></body></html>
        """
        let transport = WebFakeTransport { request, _ in webResponse(request, body: html) }
        let client = try BoneWebFetchHTTPClient(policy: BoneWebHostPolicy(allowedHosts: ["example.com"]), transport: transport)
        let input = try BoneWebFetchInput(url: "https://example.com/article")
        let output = try await client.fetch(input: input)
        XCTAssertEqual(output.url, input.url)
        XCTAssertEqual(output.finalURL, input.url)
        XCTAssertEqual(output.title, "A & B 🙂")
        XCTAssertEqual(output.text, "Hello world & 🙂 <data> © &unknown;")
        XCTAssertFalse(output.truncated)
        XCTAssertEqual(output.contentTrust, .untrustedData)
        let requests = await transport.snapshot()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.1, 2 * 1_024 * 1_024)
        XCTAssertNil(requests.first?.0.value(forHTTPHeaderField: "X-Subscription-Token"))
    }

    func testFetchUTF8TruncationAndSerializedBudget() async throws {
        let transport = WebFakeTransport { request, _ in
            webResponse(request, body: String(repeating: "文\"🙂", count: 5_000), contentType: "text/plain; charset=utf-8")
        }
        let policy = try BoneWebHostPolicy(allowedHosts: ["example.com"])
        let client = try BoneWebFetchHTTPClient(policy: policy, transport: transport, maximumTextBytes: 1_024, maximumOutputBytes: 512)
        let output = try await client.fetch(input: BoneWebFetchInput(url: "https://example.com", maximumTextBytes: 32_768))
        XCTAssertTrue(output.truncated)
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(output).count, 512)
        XCTAssertLessThanOrEqual(output.text.utf8.count, 1_024)
        XCTAssertFalse(output.text.contains("�"))
        let tiny = try BoneWebFetchHTTPClient(policy: policy, transport: transport, maximumOutputBytes: 1)
        await assertWebError(.responseTooLarge) { _ = try await tiny.fetch(input: BoneWebFetchInput(url: "https://example.com")) }
        let unicode = WebFakeTransport { request, _ in webResponse(request, body: "<p>文🙂文</p>") }
        let unicodeClient = try BoneWebFetchHTTPClient(policy: policy, transport: unicode)
        let short = try await unicodeClient.fetch(input: BoneWebFetchInput(url: "https://example.com", maximumTextBytes: 6))
        XCTAssertEqual(short.text, "文")
        XCTAssertTrue(short.truncated)
    }

    func testFetchFailsClosedWithoutRetry() async throws {
        let policy = try BoneWebHostPolicy(allowedHosts: ["example.com", "other.example.com"])
        let cases: [(BoneWebError, WebFakeTransport.Handler)] = [
            (.redirectNotAllowed, { request, _ in webResponse(request, body: "sensitive", status: 302) }),
            (.redirectNotAllowed, { request, _ in webResponse(request, body: "sensitive", finalURL: URL(string: "https://other.example.com")) }),
            (.httpFailure, { request, _ in webResponse(request, body: "sensitive", status: 503) }),
            (.responseTooLarge, { request, _ in webResponse(request, body: String(repeating: "x", count: 65)) }),
            (.unsupportedContentType, { request, _ in webResponse(request, body: "binary", contentType: "application/pdf") }),
            (.invalidResponse, { request, _ in .init(url: request.url!, statusCode: 200, headers: ["Content-Type": "text/html"], body: Data([0xFF])) })
        ]
        for (error, handler) in cases {
            let transport = WebFakeTransport(handler)
            let client = try BoneWebFetchHTTPClient(policy: policy, transport: transport, maximumResponseBytes: 64)
            await assertWebError(error) { _ = try await client.fetch(input: BoneWebFetchInput(url: "https://example.com")) }
            let requests = await transport.snapshot()
            XCTAssertEqual(requests.count, 1)
        }
        let transport = WebFakeTransport { _, _ in throw URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLStringErrorKey: "sensitive-url"]) }
        let client = try BoneWebFetchHTTPClient(policy: policy, transport: transport)
        await assertWebError(.hostNotAllowed) { _ = try await client.fetch(input: BoneWebFetchInput(url: "https://denied.example.com")) }
        let denied = await transport.snapshot()
        XCTAssertTrue(denied.isEmpty)
        await assertWebError(.requestFailed) { _ = try await client.fetch(input: BoneWebFetchInput(url: "https://example.com")) }
        let failed = await transport.snapshot()
        XCTAssertEqual(failed.count, 1)
    }

    func testBraveHeaderQueryCountPageMappingAndKeyIsolation() async throws {
        let key = "offline-test-subscription-key"
        let transport = WebFakeTransport { request, _ in
            webResponse(request, body: #"{"type":"search","query":{"more_results_available":true},"web":{"results":[{"title":"Swift &amp; Tools","url":"https://example.com/source","description":"A <strong>safe</strong> snippet"}]}}"#, contentType: "application/json; charset=utf-8")
        }
        let client = try BoneBraveSearchClient(apiKey: key, policy: BoneWebHostPolicy(allowedHosts: ["api.search.brave.com"]), transport: transport)
        let input = try BoneWebSearchInput(query: "swift + & 中文", count: 3, page: 2)
        let output = try await client.search(input: input)
        XCTAssertEqual(output.provider, "brave")
        XCTAssertEqual(output.nextPage, 3)
        XCTAssertEqual(output.results.first?.title, "Swift & Tools")
        XCTAssertEqual(output.results.first?.url, "https://example.com/source")
        XCTAssertEqual(output.results.first?.snippet, "A safe snippet")
        XCTAssertEqual(output.contentTrust, .untrustedData)
        let calls = await transport.snapshot()
        let request = try XCTUnwrap(calls.first?.0)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.search.brave.com")
        XCTAssertEqual(request.url?.path, "/res/v1/web/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.url!.absoluteString.contains("%2B"))
        let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(values, ["q": input.query, "count": "3", "offset": "2"])
        XCTAssertEqual(calls.first?.1, 1_024 * 1_024)
        for description in [request.url!.absoluteString, String(decoding: try JSONEncoder().encode(input), as: UTF8.self),
                            String(decoding: try JSONEncoder().encode(output), as: UTF8.self), String(describing: client), String(reflecting: client)] {
            XCTAssertFalse(description.contains(key))
        }
        XCTAssertEqual(try JSONDecoder().decode(BoneWebSearchOutput.self, from: JSONEncoder().encode(output)), output)
        let lastPage = try await client.search(input: BoneWebSearchInput(query: "swift", page: 9))
        XCTAssertNil(lastPage.nextPage)
    }

    func testBraveMaximumUTF8QueryAndBoundedFields() async throws {
        let longTitle = String(repeating: "文", count: 500)
        let longSnippet = String(repeating: "🙂", count: 1_000)
        let body = try JSONSerialization.data(withJSONObject: ["type": "search", "web": ["results": [["title": longTitle, "url": "https://example.com", "description": longSnippet]]]])
        let transport = WebFakeTransport { request, _ in .init(url: request.url!, statusCode: 200, headers: ["Content-Type": "application/json"], body: body) }
        let client = try BoneBraveSearchClient(apiKey: "offline-key", policy: BoneWebHostPolicy(allowedHosts: ["api.search.brave.com"]), transport: transport)
        let query = String(repeating: "文", count: 682) + "ab"
        XCTAssertEqual(query.utf8.count, 2_048)
        let output = try await client.search(input: BoneWebSearchInput(query: query))
        XCTAssertLessThanOrEqual(output.results[0].title.utf8.count, 512)
        XCTAssertLessThanOrEqual(output.results[0].snippet.utf8.count, 2_048)
        XCTAssertFalse(output.results[0].snippet.contains("�"))
        XCTAssertNil(output.nextPage)
    }

    func testBraveInvalidHTTPJSONResultAndCredentialEchoAreSafe() async throws {
        let key = "offline-secret-key"
        let bodies: [(BoneWebError, String, Int, String)] = [
            (.invalidResponse, "raw-private-body-" + key, 200, "application/json"),
            (.invalidResponse, #"{"type":"error"}"#, 200, "application/json"),
            (.invalidResponse, #"{"type":"search"}"#, 200, "application/json"),
            (.invalidResponse, #"{"type":"search","web":{"results":[{"title":"x","url":"https://example.com","description":"x"},{"title":"y","url":"https://example.com","description":"y"}]}}"#, 200, "application/json"),
            (.invalidResponse, #"{"type":"search","web":{"results":[{"title":"x","url":"https://127.0.0.1","description":"x"}]}}"#, 200, "application/json"),
            (.invalidResponse, #"{"type":"search","web":{"results":[{"title":"x"}]}}"#, 200, "application/json"),
            (.invalidResponse, "{\"type\":\"search\",\"web\":{\"results\":[{\"title\":\"x\",\"url\":\"https://example.com\",\"description\":\"" + key + "\"}]}}", 200, "application/json"),
            (.httpFailure, "raw-private-body-" + key, 429, "application/json"),
            (.redirectNotAllowed, "raw-private-body-" + key, 307, "application/json"),
            (.unsupportedContentType, "raw-private-body-" + key, 200, "text/html"),
            (.responseTooLarge, String(repeating: "x", count: 513), 200, "application/json")
        ]
        for (expected, body, status, contentType) in bodies {
            let transport = WebFakeTransport { request, _ in webResponse(request, body: body, contentType: contentType, status: status) }
            let client = try BoneBraveSearchClient(apiKey: key, policy: BoneWebHostPolicy(allowedHosts: ["api.search.brave.com"]), transport: transport, maximumResponseBytes: 512)
            do {
                _ = try await client.search(input: BoneWebSearchInput(query: "swift", count: 1))
                XCTFail("Expected a safe failure")
            } catch {
                XCTAssertEqual(error as? BoneWebError, expected)
                for message in [String(describing: error), error.localizedDescription] {
                    XCTAssertFalse(message.contains(key))
                    XCTAssertFalse(message.contains("raw-private-body"))
                    XCTAssertFalse(message.contains("https://"))
                }
            }
            let calls = await transport.snapshot()
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testReplaceableProviderHandlerContextAndOutputChecks() async throws {
        let tool = BoneWebSearchTool<WebScope> { input, context in
            guard context.permitted else { throw BoneWebError.scopeDenied }
            return try .init(results: [.init(title: "Source", url: "https://example.com", snippet: input.query)], provider: "host_provider")
        }
        let output = try await tool.execute(input: BoneWebSearchInput(query: "question"), context: .init(permitted: true))
        XCTAssertEqual(output.provider, "host_provider")
        XCTAssertEqual(output.results.first?.snippet, "question")
        let wrongPage = BoneWebSearchTool<WebScope> { _, _ in try .init(results: [], provider: "custom", nextPage: 5) }
        await assertWebError(.invalidResponse) { _ = try await wrongPage.execute(input: BoneWebSearchInput(query: "q"), context: .init(permitted: true)) }
        let wrongSource = BoneWebFetchTool<WebScope> { _, _ in
            try .init(url: "https://other.example.com", finalURL: "https://other.example.com", title: "", text: "", truncated: false)
        }
        await assertWebError(.invalidResponse) { _ = try await wrongSource.execute(input: BoneWebFetchInput(url: "https://example.com"), context: .init(permitted: true)) }
    }

    func testCancellationPropagatesToInjectedTransport() async throws {
        for searching in [false, true] {
            let started = WebSignal()
            let cancelled = WebSignal()
            let transport = WebFakeTransport { _, _ in
                await started.signal()
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { await cancelled.signal(); throw error }
                throw BoneWebError.requestFailed
            }
            let policy = try BoneWebHostPolicy(allowedHosts: ["example.com", "api.search.brave.com"])
            let fetch = BoneWebFetchTool<WebScope>(client: try BoneWebFetchHTTPClient(policy: policy, transport: transport)) { _, _ in }
            let search = BoneWebSearchTool<WebScope>(client: try BoneBraveSearchClient(apiKey: "offline-key", policy: policy, transport: transport)) { _, _ in }
            let task = Task {
                if searching { _ = try await search.execute(input: BoneWebSearchInput(query: "swift"), context: .init(permitted: true)) }
                else { _ = try await fetch.execute(input: BoneWebFetchInput(url: "https://example.com"), context: .init(permitted: true)) }
            }
            await started.wait()
            task.cancel()
            do { _ = try await task.value; XCTFail("Cancellation must propagate") }
            catch { XCTAssertTrue(error is CancellationError) }
            await cancelled.wait()
            let calls = await transport.snapshot()
            XCTAssertEqual(calls.count, 1)
        }
    }

    func testURLSessionTransportBoundsAndCancellationWithoutNetwork() async throws {
        let transport = BoneURLSessionWebTransport(makeConfiguration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WebOfflineURLProtocol.self]
            return configuration
        })
        for path in ["chunks", "declared"] {
            let request = URLRequest(url: URL(string: "https://example.com/" + UUID().uuidString + "/" + path)!)
            await assertWebError(.responseTooLarge) { _ = try await transport.send(request: request, maximumResponseBytes: 8) }
        }
        let redirectURL = URL(string: "https://example.com/" + UUID().uuidString + "/redirect")!
        var redirectRequest = URLRequest(url: redirectURL)
        redirectRequest.setValue("offline-key", forHTTPHeaderField: "X-Subscription-Token")
        await assertWebError(.redirectNotAllowed) { _ = try await transport.send(request: redirectRequest, maximumResponseBytes: 8) }
        let url = URL(string: "https://example.com/" + UUID().uuidString + "/cancel")!
        let task = Task { try await transport.send(request: URLRequest(url: url), maximumResponseBytes: 8) }
        await WebOfflineURLProtocol.events.waitForStart(url.absoluteString)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        await WebOfflineURLProtocol.events.waitForStop(url.absoluteString)
    }
}

private actor WebProtocolEvents {
    private var starts = Set<String>()
    private var stops = Set<String>()
    private var startWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var stopWaiters: [String: CheckedContinuation<Void, Never>] = [:]
    func start(_ url: String) { starts.insert(url); startWaiters.removeValue(forKey: url)?.resume() }
    func stop(_ url: String) { stops.insert(url); stopWaiters.removeValue(forKey: url)?.resume() }
    func waitForStart(_ url: String) async {
        if starts.contains(url) { return }
        await withCheckedContinuation { startWaiters[url] = $0 }
    }
    func waitForStop(_ url: String) async {
        if stops.contains(url) { return }
        await withCheckedContinuation { stopWaiters[url] = $0 }
    }
}

/// Intercepts every request: these tests cannot fall through to a network connection.
private final class WebOfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static let events = WebProtocolEvents()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Task { await Self.events.start(url.absoluteString) }
        if url.lastPathComponent == "cancel" { return }
        if url.lastPathComponent == "redirect" {
            let target = URL(string: "https://other.example.com/redirect-target")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            #if canImport(FoundationNetworking)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            #else
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            #endif
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if url.lastPathComponent == "redirect-target" {
            client?.urlProtocol(self, didFailWithError: BoneWebError.requestFailed)
            return
        }
        let headers = url.lastPathComponent == "declared" ? ["Content-Length": "16"] : [:]
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 6))
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 6))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        let url = request.url!.absoluteString
        Task { await Self.events.stop(url) }
    }
}
