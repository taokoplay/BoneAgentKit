import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class CompatibleModelDiscoveryTests: XCTestCase {
    func testOpenAITriesBaseFirstThenAddsV1OnTheSameOrigin() async throws {
        let transport = CompatibleListTransport([
            .init(statusCode: 404, data: Data()),
            .init(statusCode: 200, data: Data(#"{"models":[{"slug":"remote-model","display_name":"Remote"},{"id":"remote-model"}]}"#.utf8)),
        ])
        let service = try BoneInferenceService.bundled(transport: transport)
        let input = URL(string: "https://gateway.example.invalid:8443/proxy")!
        let list = try await service.modelList(forProvider: "OpenAICompatible", configuration: .init(
            kind: .custom, apiKey: "fixture", baseURL: input
        ))
        let requests = await transport.requests
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, [
            "https://gateway.example.invalid:8443/proxy/models",
            "https://gateway.example.invalid:8443/proxy/v1/models",
        ])
        XCTAssertTrue(requests.allSatisfy { $0.httpMethod == "GET" && $0.timeoutInterval <= 12 })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture" })
        XCTAssertEqual(list.baseURL, input)
        XCTAssertEqual(list.discoveryOutcome, .succeeded)
        XCTAssertEqual(list.models.map(\.id), ["remote-model"])
        XCTAssertEqual(list.models.first?.displayName, "Remote")
        XCTAssertEqual(list.models.first?.origins, [.discovery])
    }

    func testOpenAIFullEndpointAcceptsAnonymousArrayAndDoesNotDuplicateV1() async throws {
        let transport = CompatibleListTransport([
            .init(statusCode: 200, data: Data(#"[{"id":"gateway-only"}]"#.utf8)),
        ])
        let service = try BoneInferenceService.bundled(transport: transport)
        let input = URL(string: "https://gateway.example.invalid/proxy/v1/chat/completions/")!
        let list = try await service.modelList(forProvider: "OpenAICompatible", configuration: .init(
            kind: .custom, apiKey: "", baseURL: input, usesFullEndpointURL: true
        ))
        let requests = await transport.requests
        XCTAssertEqual(requests.compactMap { $0.url?.absoluteString }, ["https://gateway.example.invalid/proxy/v1/models"])
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(requests.first?.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertEqual(list.discoveryOutcome, .succeeded)
        XCTAssertEqual(list.models.map(\.id), ["gateway-only"])
    }

    func testAnthropicFullEndpointUsesOneV1AndListSpecificHeaders() async throws {
        let transport = CompatibleListTransport([
            .init(statusCode: 200, data: Data(#"{"data":[{"id":"gateway-claude","display_name":"Gateway Claude"}]}"#.utf8)),
        ])
        let service = try BoneInferenceService.bundled(transport: transport)
        let input = URL(string: "https://gateway.example.invalid/tenant/v1/messages")!
        let entry = try XCTUnwrap(service.provider(ident: "AnthropicCompatible"))
        let endpoint = "https://gateway.example.invalid/tenant/v1/models?limit=1000"
        XCTAssertEqual(try service.endpoint(for: entry, operation: "models", overrideBaseURL: input)?.absoluteString, endpoint)
        let list = try await service.modelList(forProvider: entry.ident, configuration: .init(
            kind: .anthropic, apiKey: "fixture", baseURL: input, authenticationMode: .anthropicDual,
            usesFullEndpointURL: true
        ))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "fixture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(list.models.first?.displayName, "Gateway Claude")
    }

    func testUnknownFullEndpointAndMismatchedOperationDoNotSendRequests() async throws {
        let transport = CompatibleListTransport([])
        let service = try BoneInferenceService.bundled(transport: transport)
        for path in ["/custom/conversation", "/v1/messages", "/v1/responses"] {
            let list = try await service.modelList(forProvider: "OpenAICompatible", configuration: .init(
                kind: .custom, apiKey: "fixture", baseURL: URL(string: "https://gateway.example.invalid" + path)!,
                usesFullEndpointURL: true
            ))
            XCTAssertEqual(list.discoveryOutcome, .notRequested)
            XCTAssertTrue(list.models.isEmpty)
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testEmptyVersionedListDoesNotGuessAnAlternativeOrDefaultModel() async throws {
        let transport = CompatibleListTransport([.init(statusCode: 200, data: Data(#"{"data":[]}"#.utf8))])
        let service = try BoneInferenceService.bundled(transport: transport)
        let list = try await service.modelList(forProvider: "OpenAICompatible", configuration: .init(
            kind: .custom, apiKey: "fixture", baseURL: URL(string: "https://gateway.example.invalid/v1")!
        ))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(list.discoveryOutcome, .transportFailure(.invalidResponse))
        XCTAssertTrue(list.models.isEmpty)
    }

    func testRejectsEmbeddedCredentialsAndQueryBeforeRequesting() async throws {
        let transport = CompatibleListTransport([])
        let service = try BoneInferenceService.bundled(transport: transport)
        for address in ["https://user:password@gateway.example.invalid/v1", "https://gateway.example.invalid/v1?route=1"] {
            do {
                _ = try await service.modelList(forProvider: "OpenAICompatible", configuration: .init(
                    kind: .custom, apiKey: "fixture", baseURL: URL(string: address)!
                ))
                XCTFail("Expected invalidEndpoint")
            } catch {
                XCTAssertEqual(error as? BoneInferenceTransportError, .invalidEndpoint)
            }
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }
}

private actor CompatibleListTransport: BoneInferenceHTTPTransport {
    private var replies: [BoneInferenceHTTPResponse]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [BoneInferenceHTTPResponse]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        requests.append(request)
        guard !replies.isEmpty else { throw BoneInferenceTransportError.invalidConfiguration }
        return replies.removeFirst()
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        XCTFail("Compatible discovery must not retry the same candidate")
        return try await send(request)
    }

    func sendEventStream(
        _ request: URLRequest, options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }
}
