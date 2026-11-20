import Foundation
import Testing
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct ChatCatalogTests: Sendable {
    @Test
    func providerChoicesAndMetadataFollowBundledCatalogOrder() throws {
        let catalog = try BoneInferenceProviderCatalog.bundled()
        let entries = catalog.providers.filter { $0.apiPaths["chat"] != nil }
        let providers = DemoChatProvider.allCases
        #expect(!entries.isEmpty)
        #expect(providers.map(\.rawValue) == entries.map(\.ident))
        #expect(providers.map(\.id) == entries.map(\.ident))
        for (provider, entry) in zip(providers, entries) {
            #expect(provider.catalogIdent == entry.ident)
            #expect(provider.title == entry.title)
            #expect(provider.iconID == entry.iconID)
            #expect(provider.defaultBaseURL == entry.defaultBaseURL?.absoluteString ?? "")
            #expect(provider.defaultModelID == entry.models.first {
                !$0.deprecated && $0.capabilities.contains(.chat)
            }?.id ?? "")
            #expect(provider.kind == entry.providerKind)
            #expect(provider.authenticationMode == entry.authenticationMode)
            #expect(!provider.isLegacyOpenAIConnection)
        }
        for entry in catalog.providers where entry.apiPaths["chat"] == nil {
            #expect(!providers.contains { $0.catalogIdent == entry.ident })
        }
    }

    @Test(arguments: ["Zhipu", "ZhipuCodingPlan"])
    func zhipuLoadsAccountModelsWithoutChoosingADefault(ident: String) async throws {
        let provider = DemoChatProvider(rawValue: ident)
        var settings = DemoLiveChatSettings()
        settings.selectProvider(provider)
        #expect(settings.modelID.isEmpty)
        #expect(provider.usesAccountModelList)
        let body = Data(#"{"data":[{"id":"glm-5.3"},{"id":"glm-5.3-flash"}]}"#.utf8)
        let transport = ChatCatalogHTTPStub(.response(200, body))
        let catalog = try DemoChatCatalog(catalog: .bundled(), transport: transport)
        #expect(try DemoChatCatalog.chatModels(in: catalog.localModels(for: settings)).isEmpty)
        #expect(await transport.requests.isEmpty)
        let listing = try await catalog.modelList(for: settings, apiKey: ChatCatalogFixtures.key)
        #expect(listing.discoveryOutcome == .succeeded)
        #expect(DemoChatCatalog.chatModels(in: listing).map(\.id) == ["glm-5.3", "glm-5.3-flash"])
        #expect(settings.modelID.isEmpty)

        settings.modelID = "glm-5.2"
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(DemoLiveChatSettings.self, from: saved).modelID == "glm-5.2")
    }

    @Test
    func localModelsNeedNoModelOrKeyAndNeverUseTransport() async throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        let transport = ChatCatalogHTTPStub(.failure(ChatCatalogFixtures.networkFailure))
        let catalog = DemoChatCatalog(catalog: bundled, transport: transport)
        for provider in DemoChatProvider.allCases {
            let entry = try #require(bundled.provider(ident: provider.catalogIdent))
            var settings = ChatCatalogFixtures.settings(provider: provider)
            settings.baseURL = "invalid URL"
            settings.modelID = ""
            settings.maximumOutputTokens = 0
            settings.systemPrompt = String(repeating: "x", count: 16_385)
            let list = try catalog.localModels(for: settings)
            #expect(list.models.map(\.id) == entry.models.map(\.id))
            #expect(list.baseURL == entry.defaultBaseURL)
            #expect(list.discoveryOutcome == .notRequested)
            #expect(DemoChatCatalog.chatModels(in: list).map(\.id) == entry.models.filter {
                !$0.deprecated && $0.capabilities.contains(.chat)
            }.map(\.id))
            #expect(list.models.allSatisfy { $0.origins == [.catalog] })
        }
        var overridden = ChatCatalogFixtures.settings()
        overridden.baseURL = "  https://catalog-proxy.invalid/custom/v1  "
        let list = try catalog.localModels(for: overridden)
        let entry = try #require(bundled.provider(ident: overridden.provider.catalogIdent))
        let baseURL = try #require(URL(string: overridden.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(list.baseURL == baseURL)
        for model in list.models {
            #expect(model.chatEndpoint == (try entry.resolvedEndpoint(
                operation: "chat", modelID: model.id, overrideBaseURL: baseURL
            )))
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func chatFilteringUsesDeclaredCapabilitiesAndDeprecation() throws {
        let entry = ChatCatalogFixtures.entry(models: [
            .init(id: "looks-like-an-image", displayName: "Chat", capabilities: [.chat], protocolVariant: .openAI),
            .init(id: "looks-like-chat", displayName: "Image", capabilities: [.image], protocolVariant: .openAI),
            .init(id: "retired-chat", displayName: "Retired", capabilities: [.chat], protocolVariant: .openAI, deprecated: true),
        ])
        let list = try BoneInferenceProviderModelList(entry: entry, discovered: [
            .init(id: "unknown-image-name", displayName: "Unknown"),
            .init(id: "explicit-image", displayName: "Image", capabilities: [.image]),
            .init(id: "explicit-chat", displayName: "Chat", capabilities: [.chat]),
        ])
        #expect(DemoChatCatalog.chatModels(in: list).map(\.id) == [
            "looks-like-an-image", "unknown-image-name", "explicit-chat",
        ])
    }

    @Test
    func everyChatProviderHasSDKThreeTimesPNGIcon() throws {
        let catalog = try DemoChatCatalog()
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        for provider in DemoChatProvider.allCases {
            let data = try catalog.iconData(for: provider)
            #expect(data.starts(with: signature))
            #expect(data == (try catalog.catalog.iconData(iconID: provider.iconID, scale: 3)))
        }
    }

    @Test
    func discoveryAcceptsEmptyModelFollowsUserBaseAndMergesSDKOrigins() async throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        let entry = try #require(bundled.provider(ident: DemoChatProvider.openAI.catalogIdent))
        let knownID = try #require(entry.models.first { !$0.deprecated && $0.capabilities.contains(.chat) }?.id)
        let discoveredID = "fixture-future-model"
        let body = try JSONSerialization.data(withJSONObject: [
            "data": [["id": knownID], ["id": discoveredID, "name": "Future Model"]],
        ])
        let transport = ChatCatalogHTTPStub(.response(200, body))
        let catalog = DemoChatCatalog(catalog: bundled, transport: transport)
        var settings = ChatCatalogFixtures.settings()
        settings.baseURL = "https://user-catalog.invalid/proxy/v1"
        settings.modelID = ""
        settings.maximumOutputTokens = 0
        settings.systemPrompt = String(repeating: "x", count: 16_385)
        let configuration = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(configuration.baseURL.absoluteString == settings.baseURL)
        ChatCatalogFixtures.expectError(.missingModel) {
            _ = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        }
        let list = try await catalog.modelList(for: settings, apiKey: ChatCatalogFixtures.key)
        #expect(list.discoveryOutcome == .succeeded)
        #expect(list.models.map(\.id) == entry.models.map(\.id) + [discoveredID])
        #expect(list.models.first { $0.id == knownID }?.origins == [.catalog, .discovery])
        let remote = try #require(list.models.first { $0.id == discoveredID })
        #expect(remote.origins == [.discovery])
        #expect(remote.catalogModel == nil)
        #expect(remote.capabilities.isEmpty)
        #expect(DemoChatCatalog.chatModels(in: list).contains { $0.id == discoveredID })
        let requests = await transport.requests
        try #require(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url == (try entry.resolvedEndpoint(
            operation: "models", overrideBaseURL: configuration.baseURL
        )))
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(ChatCatalogFixtures.key)")
    }

    @Test(arguments: [500, 200])
    func upstreamFailureFallsBackWithoutReportingDiscoverySuccess(status: Int) async throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        let entry = try #require(bundled.provider(ident: DemoChatProvider.openAI.catalogIdent))
        let transport = ChatCatalogHTTPStub(.response(status, Data(#"{"error":"fixture-upstream-error"}"#.utf8)))
        let catalog = DemoChatCatalog(catalog: bundled, transport: transport)
        let list = try await catalog.modelList(for: ChatCatalogFixtures.settings(), apiKey: ChatCatalogFixtures.key)
        let expected: BoneInferenceProviderModelList.DiscoveryOutcome = status == 500
            ? .transportFailure(.httpStatus(500)) : .transportFailure(.invalidResponse)
        #expect(list.discoveryOutcome == expected)
        #expect(list.models.map(\.id) == entry.models.map(\.id))
        #expect(list.models.allSatisfy { $0.origins == [.catalog] })
        #expect(await transport.requests.count == 1)
    }

    @Test
    func injectedCatalogUsesSDKServiceAndItsOwnFallbackModels() async throws {
        let entry = ChatCatalogFixtures.entry(models: [
            .init(id: "fixture-injected-model", displayName: "Injected", capabilities: [.chat], protocolVariant: .openAI),
        ])
        let transport = ChatCatalogHTTPStub(.failure(ChatCatalogFixtures.networkFailure))
        let catalog = DemoChatCatalog(catalog: ChatCatalogFixtures.catalog(entry), transport: transport)
        var settings = ChatCatalogFixtures.settings()
        settings.modelID = ""
        let list = try await catalog.modelList(for: settings, apiKey: ChatCatalogFixtures.key)
        #expect(list.discoveryOutcome == .transportFailure(ChatCatalogFixtures.networkFailure))
        #expect(list.models.map(\.id) == entry.models.map(\.id))
        #expect(await transport.requests.count == 1)
    }

    @Test
    func compatibleCatalogDiscoversWithoutAKeyAndRetainsChatEndpointBehavior() async throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        let transport = ChatCatalogHTTPStub(.response(200, Data(#"{"data":[{"id":"fixture-gateway-model"}]}"#.utf8)))
        let catalog = DemoChatCatalog(catalog: bundled, transport: transport)
        var settings = DemoLiveChatSettings()
        settings.selectProvider(.customOpenAI)
        settings.baseURL = "https://catalog-fixture.invalid/v1"
        #expect(settings.modelID.isEmpty)
        let local = try catalog.localModels(for: settings)
        #expect(local.models.isEmpty)
        #expect(await transport.requests.isEmpty)
        let discovered = try await catalog.modelList(for: settings, apiKey: "")
        #expect(discovered.models.map(\.id) == ["fixture-gateway-model"])
        #expect(discovered.discoveryOutcome == .succeeded)
        #expect(settings.modelID.isEmpty)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.absoluteString } == ["https://catalog-fixture.invalid/v1/models"])
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)

        settings.modelID = "user-supplied-model"
        let configuration = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(configuration.kind == .custom)
        #expect(configuration.endpointOverrides["chat"] == nil)
        let request = try ChatCatalogFixtures.chatRequest(configuration)
        #expect(request.url?.absoluteString == "https://catalog-fixture.invalid/v1/chat/completions")
        settings.baseURL = "https://catalog-fixture.invalid/complete/chat/endpoint"
        settings.usesFullEndpointURL = true
        let full = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(try ChatCatalogFixtures.chatRequest(full).url?.absoluteString == settings.baseURL)
    }

    @Test
    func fullChatEndpointDiscoveryIsRejectedBeforeSendingKey() async throws {
        let transport = ChatCatalogHTTPStub(.failure(ChatCatalogFixtures.networkFailure))
        let catalog = DemoChatCatalog(catalog: try .bundled(), transport: transport)
        var settings = ChatCatalogFixtures.settings(provider: .customOpenAI)
        settings.baseURL = "https://catalog-fixture.invalid/complete/chat/endpoint"
        settings.usesFullEndpointURL = true
        let list = try await catalog.modelList(for: settings, apiKey: ChatCatalogFixtures.key)
        #expect(list.discoveryOutcome == .notRequested)
        #expect(list.models.isEmpty)
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func cancelledDiscoveryCannotPublishSDKFallback() async throws {
        let transport = ChatCatalogHTTPStub(.cancelCurrentTask)
        let catalog = DemoChatCatalog(catalog: try .bundled(), transport: transport)
        let pending = Task {
            try await catalog.modelList(for: ChatCatalogFixtures.settings(), apiKey: ChatCatalogFixtures.key)
        }
        do {
            _ = try await pending.value
            Issue.record("Cancelled discovery unexpectedly published a fallback list")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test
    func oldProviderStringsDecodeAndNewChoicesEncodeCanonicalIdentifiers() throws {
        let oldProviders = [
            ("deepSeek", DemoChatProvider.deepSeek), ("openAI", .openAI),
            ("anthropic", .anthropic), ("gemini", .gemini), ("customOpenAI", .customOpenAI),
        ]
        for (token, canonical) in oldProviders {
            let data = try JSONEncoder().encode(token)
            let provider = try JSONDecoder().decode(DemoChatProvider.self, from: data)
            #expect(provider.catalogIdent == canonical.catalogIdent)
            #expect(provider.id == canonical.id)
            let encoded = try JSONEncoder().encode(provider)
            #expect(try JSONDecoder().decode(String.self, from: encoded) == (token == "deepSeek" ? token : canonical.catalogIdent))
        }
        let bundled = try BoneInferenceProviderCatalog.bundled()
        for entry in bundled.providers {
            let provider = DemoChatProvider(rawValue: entry.ident)
            let encoded = try JSONEncoder().encode(provider)
            #expect(try JSONDecoder().decode(String.self, from: encoded) == entry.ident)
            #expect(try JSONDecoder().decode(DemoChatProvider.self, from: encoded) == provider)
        }
    }

    @Test
    func oldDeepSeekPreservesOpenAIConnectionAndCredentialScopeUntilReselected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "provider": "deepSeek", "baseURL": "https://api.deepseek.com/v1", "modelID": "deepseek-chat",
            "usesFullEndpointURL": false, "systemPrompt": "saved prompt", "enablesCalculator": true,
            "maximumOutputTokens": 1024,
        ])
        let old = try JSONDecoder().decode(DemoLiveChatSettings.self, from: data)
        let configuration = try old.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(old.provider.rawValue == "deepSeek")
        #expect(old.provider.isLegacyOpenAIConnection)
        #expect(old.provider.kind == .custom)
        #expect(old.provider.authenticationMode == .bearer)
        #expect(old.provider.supportsFullEndpointURL)
        #expect(configuration.kind == .custom)
        #expect(configuration.authenticationMode == .bearer)
        #expect(configuration.endpointOverrides.isEmpty)
        #expect(configuration.baseURL.absoluteString == "https://api.deepseek.com/v1")
        #expect(old.modelID == "deepseek-chat")
        #expect(old.credentialAccount == "Custom|base|https://api.deepseek.com/v1")
        #expect(try ChatCatalogFixtures.chatRequest(configuration).url?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
        let encoded = try JSONEncoder().encode(old)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["provider"] as? String == "deepSeek")
        #expect(try JSONDecoder().decode(DemoLiveChatSettings.self, from: encoded) == old)

        var selected = old
        selected.selectProvider(.deepSeek)
        let entry = try #require(BoneInferenceProviderCatalog.bundled().provider(ident: "DeepSeek"))
        let newConfiguration = try selected.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(selected.provider.rawValue == entry.ident)
        #expect(!selected.provider.isLegacyOpenAIConnection)
        #expect(selected.baseURL == entry.defaultBaseURL?.absoluteString)
        #expect(selected.modelID == entry.models.first { !$0.deprecated && $0.capabilities.contains(.chat) }?.id)
        #expect(newConfiguration.kind == entry.providerKind)
        #expect(newConfiguration.authenticationMode == entry.authenticationMode)
        #expect(newConfiguration.endpointOverrides == entry.apiPaths)
        #expect(selected.credentialAccount != old.credentialAccount)
        #expect(selected.systemPrompt == old.systemPrompt)
        #expect(selected.enablesCalculator == old.enablesCalculator)
    }

    @Test
    func authenticationAndOperationPathsComeFromSDKIncludingMiniMax() throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        for entry in bundled.providers where entry.apiPaths["chat"] != nil {
            let provider = DemoChatProvider(rawValue: entry.ident)
            var settings = ChatCatalogFixtures.settings(provider: provider)
            settings.modelID = provider.defaultModelID.isEmpty ? "user-supplied-model" : provider.defaultModelID
            let configuration = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
            #expect(configuration.kind == entry.providerKind)
            #expect(configuration.authenticationMode == entry.authenticationMode)
            #expect(configuration.endpointOverrides == entry.apiPaths.filter { !$0.value.isEmpty })
            #expect(configuration.userAgent == (entry.authenticationMode == .bearerWithUserAgent ? "BoneAgentLab/1.0" : nil))
            // Check authentication with a concrete path, including Google's model template catalog.
            let request = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
                configuration: configuration, operation: "fixture-authentication", defaultPath: "/fixture-authentication"
            )
            switch entry.authenticationMode {
            case .bearer, .bearerWithUserAgent:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(ChatCatalogFixtures.key)")
            case .anthropicDual:
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(ChatCatalogFixtures.key)")
                #expect(request.value(forHTTPHeaderField: "x-api-key") == ChatCatalogFixtures.key)
            case .apiKey:
                #expect(request.value(forHTTPHeaderField: "api-key") == ChatCatalogFixtures.key)
            case .googleAPIKey:
                #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == ChatCatalogFixtures.key)
            }
            if entry.authenticationMode == .bearerWithUserAgent {
                #expect(request.value(forHTTPHeaderField: "User-Agent") == "BoneAgentLab/1.0")
            }
            settings.usesFullEndpointURL = true
            if entry.providerProtocol == .anthropic && !provider.isCompatibleGateway {
                #expect(!provider.supportsFullEndpointURL)
                ChatCatalogFixtures.expectError(.unsupportedFullEndpointURL) { _ = try settings.validated() }
            } else {
                #expect(provider.supportsFullEndpointURL)
                #expect(try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key).usesFullEndpointURL)
            }
        }
        let miniMax = DemoChatProvider(rawValue: "MiniMax")
        let entry = try #require(bundled.provider(ident: miniMax.catalogIdent))
        let settings = ChatCatalogFixtures.settings(provider: miniMax)
        let configuration = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
        #expect(configuration.endpointOverrides["chat"] == entry.apiPaths["chat"])
        #expect(try ChatCatalogFixtures.chatRequest(configuration).url == entry.resolvedEndpoint(
            operation: "chat", modelID: settings.modelID, overrideBaseURL: configuration.baseURL
        ))
    }

    @Test
    func unknownProvidersAndImageOnlyChannelsAreRejectedWithFixedErrors() async throws {
        let bundled = try BoneInferenceProviderCatalog.bundled()
        let transport = ChatCatalogHTTPStub(.failure(ChatCatalogFixtures.networkFailure))
        let catalog = DemoChatCatalog(catalog: bundled, transport: transport)
        let providers = [DemoChatProvider(rawValue: ChatCatalogFixtures.key)] + bundled.providers.filter {
            $0.apiPaths["chat"] == nil
        }.map { DemoChatProvider(rawValue: $0.ident) }
        for provider in providers {
            let settings = ChatCatalogFixtures.settings(provider: provider)
            ChatCatalogFixtures.expectError(.unknownProvider) { _ = try settings.validated() }
            ChatCatalogFixtures.expectError(.unknownProvider) {
                _ = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key)
            }
            ChatCatalogFixtures.expectError(.unknownProvider) {
                _ = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
            }
            do {
                _ = try await catalog.modelList(for: settings, apiKey: ChatCatalogFixtures.key)
                Issue.record("An unknown or image-only provider unexpectedly allowed discovery")
            } catch {
                #expect(error as? DemoChatConfigurationError == .unknownProvider)
            }
        }
        let empty = DemoChatCatalog(catalog: .init(schemaVersion: 1, catalogVersion: 1, verifiedAt: "fixture", providers: []), transport: transport)
        ChatCatalogFixtures.expectError(.unknownProvider) {
            _ = try empty.localModels(for: ChatCatalogFixtures.settings())
        }
        #expect(await transport.requests.isEmpty)
        for error in [DemoChatConfigurationError.unknownProvider, .catalogUnavailable, .fullEndpointDiscovery, .unsupportedFullEndpointURL] {
            #expect(!error.message.isEmpty)
            #expect(!error.message.contains(ChatCatalogFixtures.key))
            #expect(!error.message.contains("https://"))
        }
    }

    @Test
    func discoveryRetainsURLAndKeyValidationAndSettingsCodableShape() throws {
        let valid = ChatCatalogFixtures.settings()
        for address in [
            "http://catalog-fixture.invalid", "https://user:password@catalog-fixture.invalid",
            "https://catalog-fixture.invalid?key=unsafe", "https://catalog-fixture.invalid#fragment", "",
        ] {
            var settings = valid
            settings.baseURL = address
            ChatCatalogFixtures.expectError(.invalidURL) {
                _ = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
            }
        }
        for key in ["invalid\ncredential", "invalid key", "密钥", String(repeating: "x", count: 16_385)] {
            ChatCatalogFixtures.expectError(.invalidKey) { _ = try valid.discoveryConfiguration(apiKey: key) }
        }
        ChatCatalogFixtures.expectError(.missingKey) { _ = try valid.discoveryConfiguration(apiKey: " \n ") }
        var settings = valid
        settings.maximumOutputTokens = 127
        ChatCatalogFixtures.expectError(.invalidOutputLimit) { _ = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key) }
        _ = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
        settings.maximumOutputTokens = 1024
        settings.systemPrompt = String(repeating: "x", count: 16_385)
        ChatCatalogFixtures.expectError(.systemPromptTooLarge) { _ = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key) }
        _ = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
        settings.systemPrompt = ""
        settings.modelID = String(repeating: "x", count: 257)
        ChatCatalogFixtures.expectError(.missingModel) { _ = try settings.providerConfiguration(apiKey: ChatCatalogFixtures.key) }
        _ = try settings.discoveryConfiguration(apiKey: ChatCatalogFixtures.key)
        let encoded = try JSONEncoder().encode(valid)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(object.keys) == [
            "provider", "baseURL", "modelID", "usesFullEndpointURL", "systemPrompt",
            "enablesCalculator", "maximumOutputTokens",
            "usesStreaming", "managesContext", "summarizesContext", "contextWindowTokens",
            "preservesConversation", "enablesTextResources", "visionPolicy",
            "visionTokenBase", "visionTokensPerMegapixel", "visionBindingID",
            "enablesDateTime", "enablesAskUser", "enablesWebFetch", "enablesWebSearch", "webAllowedHosts",
        ])
        #expect(!String(decoding: encoded, as: UTF8.self).contains(ChatCatalogFixtures.key))
        #expect(try JSONDecoder().decode(DemoLiveChatSettings.self, from: encoded) == valid)
        let legacy = Data(#"{"provider":"deepSeek","baseURL":"https://api.deepseek.com","modelID":"deepseek-chat","usesFullEndpointURL":false,"systemPrompt":"","enablesCalculator":false,"maximumOutputTokens":1024}"#.utf8)
        let restored = try JSONDecoder().decode(DemoLiveChatSettings.self, from: legacy)
        #expect(restored.usesStreaming && restored.managesContext)
        #expect(!restored.preservesConversation && !restored.enablesTextResources)
        #expect(restored.visionPolicy == .disabled)
        #expect(restored.provider.rawValue == "deepSeek")
    }
}

private enum ChatCatalogFixtures {
    static let key = "unit-test-catalog-key-DO-NOT-USE"
    static let networkFailure = BoneInferenceTransportError.network(
        .init(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue))

    static func settings(provider: DemoChatProvider = .openAI) -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.selectProvider(provider)
        if settings.baseURL.isEmpty { settings.baseURL = "https://catalog-fixture.invalid" }
        if settings.modelID.isEmpty { settings.modelID = "user-supplied-model" }
        return settings
    }

    static func entry(models: [BoneInferenceProviderCatalog.Model]) -> BoneInferenceProviderCatalog.Entry {
        .init(
            ident: "OpenAI", title: "Injected OpenAI", iconID: DemoChatProvider.openAI.iconID,
            providerKind: .openAI, providerProtocol: .openAI, authenticationMode: .bearer,
            defaultBaseURL: URL(string: "https://catalog-fixture.invalid/v1"), inviteURL: nil,
            documentationURL: nil, catalogMode: .local, sortOrder: 1,
            apiPaths: ["chat": "/chat/completions", "models": "/models"], discovery: nil, models: models
        )
    }

    static func catalog(_ entry: BoneInferenceProviderCatalog.Entry) -> BoneInferenceProviderCatalog {
        .init(schemaVersion: 1, catalogVersion: 1, verifiedAt: "fixture", providers: [entry])
    }

    static func chatRequest(_ configuration: BoneInferenceProviderConfiguration) throws -> URLRequest {
        try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: configuration, operation: "chat", defaultPath: "/v1/chat/completions", usesFullEndpointURL: true
        )
    }

    static func expectError(_ expected: DemoChatConfigurationError, operation: () throws -> Void) {
        do {
            try operation()
            Issue.record("Expected a configuration error")
        } catch {
            #expect(error as? DemoChatConfigurationError == expected)
        }
    }
}

private actor ChatCatalogHTTPStub: BoneInferenceHTTPTransport {
    enum Reply: Sendable {
        case response(Int, Data)
        case failure(BoneInferenceTransportError)
        case cancelCurrentTask
    }

    private let reply: Reply
    private(set) var requests: [URLRequest] = []

    init(_ reply: Reply) { self.reply = reply }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try respond(to: request)
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        try respond(to: request)
    }

    func sendEventStream(
        _ request: URLRequest, options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }

    private func respond(to request: URLRequest) throws -> BoneInferenceHTTPResponse {
        requests.append(request)
        switch reply {
        case .response(let status, let body):
            return .init(statusCode: status, data: body, headers: ["Content-Type": "application/json"])
        case .failure(let error):
            throw error
        case .cancelCurrentTask:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
    }
}
