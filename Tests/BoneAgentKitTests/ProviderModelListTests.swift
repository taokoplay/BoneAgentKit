import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class ProviderModelListTests: XCTestCase {
    private func entry(_ ident: String) throws -> BoneInferenceProviderCatalog.Entry {
        try XCTUnwrap(try BoneInferenceProviderCatalog.bundled().provider(ident: ident))
    }

    private func load(
        _ entry: BoneInferenceProviderCatalog.Entry,
        _ configuration: BoneInferenceProviderConfiguration,
        discoverer: (any BoneInferenceModelDiscovering)? = nil
    ) async throws -> BoneInferenceProviderModelList {
        try await BoneInferenceProviderModelListLoader(
            configuration: configuration,
            discoverer: discoverer
        ).load(for: entry)
    }

    // MARK: - Catalog merge

    func testLocalListingKeepsCatalogOrderAndAppendsDiscoveredModels() throws {
        let openAI = try entry("OpenAI")
        let listing = try BoneInferenceProviderModelList(entry: openAI, discovered: [
            .init(id: "gpt-future", displayName: "GPT Future"),
            .init(id: "gpt-4.1-mini", displayName: "Remote Rename"),
        ])

        XCTAssertEqual(listing.providerIdent, "OpenAI")
        XCTAssertEqual(listing.catalogMode, .local)
        XCTAssertEqual(listing.baseURL, URL(string: "https://api.openai.com/v1"))
        XCTAssertEqual(listing.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1", "gpt-future"])
        XCTAssertEqual(listing.discoveryOutcome, .notRequested)
    }

    func testDiscoveredDuplicateKeepsCatalogMetadataAndAddsOrigin() throws {
        let openAI = try entry("OpenAI")
        let listing = try BoneInferenceProviderModelList(entry: openAI, discovered: [
            .init(id: "gpt-4.1-mini", displayName: "Remote Rename", capabilities: [.image]),
        ])

        let model = try XCTUnwrap(listing.models.first)
        XCTAssertEqual(model.origins, [.catalog, .discovery])
        XCTAssertEqual(model.displayName, "GPT-4.1 Mini")
        XCTAssertEqual(model.capabilities, [.chat])
        XCTAssertNotNil(model.catalogModel)
        XCTAssertEqual(model.chatEndpoint, URL(string: "https://api.openai.com/v1/chat/completions"))
    }

    func testDiscoveredOnlyModelKeepsDescriptorCapabilitiesAndNoCatalogDeclaration() throws {
        let openAI = try entry("OpenAI")
        let listing = try BoneInferenceProviderModelList(entry: openAI, discovered: [
            .init(id: "gpt-future", displayName: "", capabilities: [.chat]),
        ])

        let model = try XCTUnwrap(listing.models.last)
        XCTAssertEqual(model.origins, [.discovery])
        XCTAssertEqual(model.displayName, "gpt-future")
        XCTAssertNil(model.catalogModel)
        XCTAssertEqual(model.capabilities, [.chat])
    }

    // MARK: - Upstream endpoints

    func testEndpointResolutionUsesConfiguredBaseURLAndDeduplicatesProviderPath() throws {
        let tokenPlan = try entry("MiMoTokenPlan")
        let override = URL(string: "https://token-plan-cn.example.invalid/anthropic")!

        XCTAssertEqual(
            try tokenPlan.resolvedEndpoint(operation: "chat"),
            URL(string: "https://token-plan-cn.xiaomimimo.com/anthropic/v1/messages")
        )
        XCTAssertEqual(
            try tokenPlan.resolvedEndpoint(operation: "chat", overrideBaseURL: override),
            URL(string: "https://token-plan-cn.example.invalid/anthropic/v1/messages")
        )
    }

    func testEndpointResolutionSubstitutesModelPlaceholder() throws {
        let google = try entry("Google")
        XCTAssertEqual(
            try google.resolvedEndpoint(operation: "chat", modelID: "gemini-2.5-flash"),
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        )
    }

    func testEndpointResolutionLeavesAbsoluteOperationPathUntouched() throws {
        let miniMax = try entry("MiniMax")
        XCTAssertEqual(
            try miniMax.resolvedEndpoint(operation: "image"),
            URL(string: "https://api.minimaxi.com/v1/image_generation")
        )
    }

    func testUndeclaredOrEmptyOperationHasNoEndpoint() throws {
        let openAI = try entry("OpenAI")
        XCTAssertNil(try openAI.resolvedEndpoint(operation: "embedding"))

        let compatible = try entry("OpenAICompatible")
        XCTAssertNil(
            try compatible.resolvedEndpoint(
                operation: "chat",
                overrideBaseURL: URL(string: "https://gateway.example.invalid/v1")!
            )
        )
    }

    // MARK: - Upstream first, catalog fallback

    func testManualProviderReturnsEmptyListingWithoutRequest() async throws {
        let compatible = try entry("OpenAICompatible")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .custom,
            apiKey: "fixture",
            baseURL: URL(string: "https://gateway.example.invalid/v1")!,
            endpointSecurityPolicy: .custom
        )
        let discoverer = RecordingDiscoverer([.init(id: "should-not-be-used", displayName: "x")])

        let listing = try await load(compatible, configuration, discoverer: discoverer)

        let sent = await discoverer.lastDiscovery
        XCTAssertTrue(listing.models.isEmpty)
        XCTAssertEqual(listing.discoveryOutcome, .notRequested)
        XCTAssertNil(sent)
    }

    func testRemoteWithoutDiscovererReturnsBuiltInListWithoutRequest() async throws {
        let agnes = try entry("Agnes")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .agnes,
            apiKey: "fixture",
            baseURL: URL(string: "https://apihub.agnes-ai.com/v1")!
        )

        let listing = try await load(agnes, configuration)

        XCTAssertTrue(listing.models.isEmpty)
        XCTAssertEqual(listing.discoveryOutcome, .notRequested)
    }

    func testRemoteDiscoverySuccessMarksDiscoveredOrigin() async throws {
        let agnes = try entry("Agnes")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .agnes,
            apiKey: "fixture",
            baseURL: URL(string: "https://apihub.agnes-ai.com/v1")!
        )
        let discoverer = RecordingDiscoverer([.init(id: "agnes-chat", displayName: "Agnes Chat")])

        let listing = try await load(agnes, configuration, discoverer: discoverer)

        XCTAssertEqual(listing.discoveryOutcome, .succeeded)
        XCTAssertEqual(listing.models.map(\.id), ["agnes-chat"])
        XCTAssertEqual(listing.models.first?.origins, [.discovery])
        XCTAssertEqual(
            listing.models.first?.chatEndpoint,
            URL(string: "https://apihub.agnes-ai.com/v1/chat/completions")
        )
        let sent = await discoverer.lastDiscovery
        XCTAssertEqual(sent?.endpoint, URL(string: "https://apihub.agnes-ai.com/v1/models"))
        XCTAssertEqual(sent?.protocol, .openAI)
        XCTAssertEqual(sent?.authenticationMode, .bearer)
    }

    func testRemoteDiscoveryFailureFallsBackToEmptyBuiltInList() async throws {
        let agnes = try entry("Agnes")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .agnes,
            apiKey: "fixture",
            baseURL: URL(string: "https://apihub.agnes-ai.com/v1")!
        )

        let listing = try await load(agnes, configuration, discoverer: FailingTransportDiscoverer())

        XCTAssertTrue(listing.models.isEmpty)
        XCTAssertEqual(listing.discoveryOutcome, .transportFailure(.invalidResponse))
    }

    func testNewAPIRemoteDerivesModelsPathFromConfiguredBaseURL() async throws {
        let newAPI = try entry("NewApi")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .newAPI,
            apiKey: "fixture",
            baseURL: URL(string: "https://gateway.example.invalid/v1")!,
            endpointSecurityPolicy: .custom
        )
        let discoverer = RecordingDiscoverer([.init(id: "custom-model", displayName: "Custom")])

        let listing = try await load(newAPI, configuration, discoverer: discoverer)

        let sent = await discoverer.lastDiscovery
        XCTAssertEqual(sent?.endpoint, URL(string: "https://gateway.example.invalid/v1/models"))
        XCTAssertEqual(
            listing.models.first?.chatEndpoint,
            URL(string: "https://gateway.example.invalid/v1/chat/completions")
        )
        XCTAssertEqual(listing.discoveryOutcome, .succeeded)
    }

    func testLocalDiscoverySuccessMergesWithBuiltInCatalog() async throws {
        let openAI = try entry("OpenAI")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        let discoverer = RecordingDiscoverer([.init(id: "gpt-future", displayName: "GPT Future")])

        let listing = try await load(openAI, configuration, discoverer: discoverer)

        let sent = await discoverer.lastDiscovery
        XCTAssertEqual(sent?.endpoint, URL(string: "https://api.openai.com/v1/models"))
        XCTAssertEqual(listing.discoveryOutcome, .succeeded)
        XCTAssertEqual(listing.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1", "gpt-future"])
    }

    func testLocalDiscoveryFailureFallsBackToBuiltInCatalog() async throws {
        let openAI = try entry("OpenAI")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        let listing = try await load(openAI, configuration, discoverer: FailingTransportDiscoverer())

        XCTAssertEqual(listing.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1"])
        XCTAssertEqual(listing.discoveryOutcome, .transportFailure(.invalidResponse))
    }

    func testLocalWithoutModelsEndpointReturnsBuiltInWithoutRequest() async throws {
        let codingPlan = try entry("ZhipuCodingPlan")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .zhipu,
            apiKey: "fixture",
            baseURL: URL(string: "https://open.bigmodel.cn/api/anthropic")!
        )
        let discoverer = RecordingDiscoverer([.init(id: "unused", displayName: "unused")])

        let listing = try await load(codingPlan, configuration, discoverer: discoverer)

        let sent = await discoverer.lastDiscovery
        XCTAssertNil(sent)
        XCTAssertFalse(listing.models.isEmpty)
        XCTAssertEqual(listing.discoveryOutcome, .notRequested)
    }

    func testNonTransportDiscovererErrorFallsBackAsGenericFailure() async throws {
        let openAI = try entry("OpenAI")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        let listing = try await load(openAI, configuration, discoverer: UnexpectedFailureDiscoverer())

        XCTAssertEqual(listing.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1"])
        XCTAssertEqual(listing.discoveryOutcome, .failed)
    }

    // MARK: - Unified path through the real discovery client

    func testListingUsesDiscoveryClientAndFollowsConfiguredAgnesSite() async throws {
        let agnes = try entry("Agnes")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .agnes,
            apiKey: "fixture",
            baseURL: URL(string: "https://apihub.agnes-ai.com/v1")!
        )
        let transport = ModelListTransport(body: #"{"data":[{"id":"agnes-live"}]}"#)
        let client = BoneInferenceModelDiscoveryClient(
            configuration: configuration,
            transport: transport
        )

        let listing = try await load(agnes, configuration, discoverer: client)

        let urls = await transport.requestURLs
        XCTAssertEqual(urls, [URL(string: "https://apihub.agnes-ai.com/v1/models")])
        XCTAssertEqual(listing.models.map(\.id), ["agnes-live"])
        XCTAssertEqual(listing.discoveryOutcome, .succeeded)
    }

    func testListingUsesDiscoveryClientForNewAPIEnvelope() async throws {
        let newAPI = try entry("NewApi")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .newAPI,
            apiKey: "fixture",
            baseURL: URL(string: "https://gateway.example.invalid/v1")!,
            endpointSecurityPolicy: .custom
        )
        let transport = ModelListTransport(
            body: #"{"success":true,"data":[{"id":"relay-model"}]}"#
        )
        let client = BoneInferenceModelDiscoveryClient(
            configuration: configuration,
            transport: transport
        )

        let listing = try await load(newAPI, configuration, discoverer: client)

        let urls = await transport.requestURLs
        XCTAssertEqual(urls, [URL(string: "https://gateway.example.invalid/v1/models")])
        XCTAssertEqual(listing.models.map(\.id), ["relay-model"])
        XCTAssertEqual(listing.discoveryOutcome, .succeeded)
        XCTAssertEqual(
            listing.models.first?.chatEndpoint,
            URL(string: "https://gateway.example.invalid/v1/chat/completions")
        )
    }

    func testListingFallsBackWhenDiscoveryClientGetsHTTPError() async throws {
        let openAI = try entry("OpenAI")
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        let transport = ModelListTransport(status: 500, body: #"{"error":"boom"}"#)
        let client = BoneInferenceModelDiscoveryClient(
            configuration: configuration,
            transport: transport
        )

        let listing = try await load(openAI, configuration, discoverer: client)

        XCTAssertEqual(listing.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1"])
        XCTAssertEqual(listing.discoveryOutcome, .transportFailure(.httpStatus(500)))
    }
}

private actor RecordingDiscoverer: BoneInferenceModelDiscovering {
    private(set) var lastDiscovery: BoneInferenceProviderCatalog.Discovery?
    private let models: [BoneInferenceModelDescriptor]

    init(_ models: [BoneInferenceModelDescriptor]) {
        self.models = models
    }

    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        lastDiscovery = discovery
        return models
    }

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data {
        throw BoneInferenceTransportError.invalidConfiguration
    }
}

private actor FailingTransportDiscoverer: BoneInferenceModelDiscovering {
    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        throw BoneInferenceTransportError.invalidResponse
    }

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data {
        throw BoneInferenceTransportError.invalidResponse
    }
}

private struct UnexpectedFailureDiscoverer: BoneInferenceModelDiscovering {
    struct Failure: Error {}

    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        throw Failure()
    }

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data {
        throw Failure()
    }
}

private actor ModelListTransport: BoneInferenceHTTPTransport {
    private(set) var requestURLs: [URL] = []
    private let status: Int
    private let body: Data

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        response(for: request)
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        response(for: request)
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }

    private func response(for request: URLRequest) -> BoneInferenceHTTPResponse {
        if let url = request.url {
            requestURLs.append(url)
        }
        return BoneInferenceHTTPResponse(statusCode: status, data: body)
    }
}
