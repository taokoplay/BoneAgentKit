import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class BoneInferenceServiceTests: XCTestCase {
    func testBundledServiceExposesCatalog() throws {
        let service = try BoneInferenceService.bundled()

        XCTAssertEqual(service.providers().count, 21)
        XCTAssertEqual(service.provider(ident: "openai")?.ident, "OpenAI")
        XCTAssertNil(service.provider(ident: "FutureProvider"))
    }

    func testModelListForProviderUsesInjectedDiscoverer() async throws {
        let service = try BoneInferenceService.bundled()
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )
        let discoverer = ServiceStubDiscoverer([
            .init(id: "gpt-future", displayName: "GPT Future"),
        ])

        let list = try await service.modelList(
            forProvider: "OpenAI",
            configuration: configuration,
            discoverer: discoverer
        )

        XCTAssertEqual(list.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1", "gpt-future"])
        XCTAssertEqual(list.discoveryOutcome, .succeeded)
    }

    func testModelListFallsBackWhenDiscoveryFails() async throws {
        let service = try BoneInferenceService.bundled()
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        let list = try await service.modelList(
            forProvider: "OpenAI",
            configuration: configuration,
            discoverer: ServiceFailingDiscoverer()
        )

        XCTAssertEqual(list.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1"])
        XCTAssertEqual(list.discoveryOutcome, .transportFailure(.invalidResponse))
    }

    func testUnknownProviderThrowsTypedFailure() async throws {
        let service = try BoneInferenceService.bundled()
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        do {
            _ = try await service.modelList(
                forProvider: "FutureProvider",
                configuration: configuration
            )
            XCTFail("Expected unknownProvider")
        } catch {
            XCTAssertEqual(
                error as? BoneInferenceService.Error,
                .unknownProvider("FutureProvider")
            )
        }
    }

    func testEndpointResolvesModelPlaceholder() throws {
        let service = try BoneInferenceService.bundled()
        let google = try XCTUnwrap(service.provider(ident: "Google"))

        XCTAssertEqual(
            try service.endpoint(for: google, operation: "chat", modelID: "gemini-2.5-flash"),
            URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent")
        )
    }

    func testServiceAcceptsInjectedCatalog() throws {
        let catalog = try BoneInferenceProviderCatalog.decode(data: Data(#"""
        {
          "schemaVersion": 1,
          "catalogVersion": 1,
          "verifiedAt": "2026-10-23",
          "providers": [
            {
              "ident": "TestProvider",
              "title": "Test",
              "icon": "icon_test",
              "adapter": "openAI",
              "authenticationMode": "bearer",
              "defaultBaseURL": "https://api.test.invalid/v1",
              "modelCatalogMode": "local",
              "sortOrder": 1,
              "apiPaths": { "chat": "/chat/completions" },
              "models": [
                {
                  "id": "test-model",
                  "displayName": "Test Model",
                  "capabilities": ["chat"],
                  "protocolVariant": "openAI",
                  "deprecated": false
                }
              ]
            }
          ]
        }
        """#.utf8))
        let service = BoneInferenceService(catalog: catalog)

        XCTAssertEqual(service.providers().map(\.ident), ["TestProvider"])
        XCTAssertEqual(
            try service.endpoint(for: XCTUnwrap(service.provider(ident: "testprovider")), operation: "chat"),
            URL(string: "https://api.test.invalid/v1/chat/completions")
        )
    }
}

private actor ServiceStubDiscoverer: BoneInferenceModelDiscovering {
    private let models: [BoneInferenceModelDescriptor]

    init(_ models: [BoneInferenceModelDescriptor]) {
        self.models = models
    }

    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        models
    }

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data {
        throw BoneInferenceTransportError.invalidConfiguration
    }
}

private actor ServiceFailingDiscoverer: BoneInferenceModelDiscovering {
    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        throw BoneInferenceTransportError.invalidResponse
    }

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data {
        throw BoneInferenceTransportError.invalidResponse
    }
}
