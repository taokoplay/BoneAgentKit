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

    func testModelListUsesInjectedTransportAndMergesDiscovery() async throws {
        let transport = ServiceModelTransport(
            body: #"{"data":[{"id":"gpt-future"}]}"#
        )
        let service = BoneInferenceService(
            catalog: try .bundled(),
            transport: transport
        )
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        let list = try await service.modelList(
            forProvider: "OpenAI",
            configuration: configuration
        )

        XCTAssertEqual(list.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1", "gpt-future"])
        XCTAssertEqual(list.discoveryOutcome, .succeeded)
        let url = await transport.requestURL
        XCTAssertEqual(url, URL(string: "https://api.openai.com/v1/models"))
    }

    func testModelListFallsBackWhenTransportFails() async throws {
        let transport = ServiceModelTransport(status: 500, body: #"{"error":"boom"}"#)
        let service = BoneInferenceService(
            catalog: try .bundled(),
            transport: transport
        )
        let configuration = BoneInferenceProviderConfiguration(
            kind: .openAI,
            apiKey: "fixture",
            baseURL: URL(string: "https://api.openai.com/v1")!
        )

        let list = try await service.modelList(
            forProvider: "OpenAI",
            configuration: configuration
        )

        XCTAssertEqual(list.models.map(\.id), ["gpt-4.1-mini", "gpt-image-1"])
        XCTAssertEqual(list.discoveryOutcome, .transportFailure(.httpStatus(500)))
    }

    func testGatewayErrorEnvelopeMapsToInvalidCredential() async throws {
        let transport = ServiceModelTransport(
            body: #"{"code":401,"msg":"令牌已过期或验证不正确","success":false}"#
        )
        let service = BoneInferenceService(
            catalog: try .bundled(),
            transport: transport
        )
        let configuration = BoneInferenceProviderConfiguration(
            kind: .zhipu,
            apiKey: "fixture",
            baseURL: URL(string: "https://open.bigmodel.cn/api/anthropic")!,
            userAgent: "BoneAgentKit-tests"
        )

        let list = try await service.modelList(
            forProvider: "ZhipuCodingPlan",
            configuration: configuration
        )

        XCTAssertEqual(list.discoveryOutcome, .transportFailure(.invalidCredential))
        XCTAssertEqual(list.models.map(\.id), ["glm-5.2", "glm-5.1"])
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

private actor ServiceModelTransport: BoneInferenceHTTPTransport {
    private(set) var requestURL: URL?
    private let status: Int
    private let body: Data

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        record(request)
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        record(request)
    }

    func sendEventStream(
        _ request: URLRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }

    private func record(_ request: URLRequest) -> BoneInferenceHTTPResponse {
        requestURL = request.url
        return BoneInferenceHTTPResponse(statusCode: status, data: body)
    }
}
