import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class AgnesModelDiscoveryTests: XCTestCase {
    private var discovery: BoneInferenceProviderCatalog.Discovery {
        .init(endpoint: URL(string: "https://apihub.agnes-ai.cn/v1/models")!, protocol: .openAI, authenticationMode: .bearer)
    }

    func testBundledAgnesUsesRemoteEmptyCatalog() throws {
        let provider = try XCTUnwrap(BoneInferenceProviderCatalog.bundled().provider(ident: "Agnes"))
        XCTAssertTrue(provider.models.isEmpty)
        // Verify the encoded source contract independently of Host selection logic.
        let data = try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/BoneAgentKit/Resources/AIProviderDefaults.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        let agnes = try XCTUnwrap(providers.first { $0["ident"] as? String == "Agnes" })
        XCTAssertEqual(agnes["modelCatalogMode"] as? String, "remote")
        XCTAssertEqual(agnes["defaultBaseURL"] as? String, "https://apihub.agnes-ai.cn/v1")
    }

    func testDiscoveryFollowsConfiguredBaseURL() async throws {
        for base in ["https://apihub.agnes-ai.cn/v1", "https://apihub.agnes-ai.com/v1/", "https://gateway.example.com/custom/v1"] {
            let transport = AgnesDiscoveryTransport()
            let client = BoneInferenceModelDiscoveryClient(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: base)!), transport: transport)
            let models = try await client.discoverAgnesModels()
            XCTAssertEqual(models.map(\.id), ["future-model"])
            let url = await transport.url
            XCTAssertEqual(url, URL(string: base)!.appendingPathComponent("models"))
        }
    }

    func testFailureDoesNotReturnBundledFallback() async throws {
        let transport = AgnesDiscoveryTransport(status: 500)
        let client = BoneInferenceModelDiscoveryClient(configuration: .init(kind: .agnes, apiKey: "fixture", baseURL: URL(string: "https://apihub.agnes-ai.com/v1")!), transport: transport)
        do {
            _ = try await client.discover(using: discovery)
            XCTFail("Expected remote failure")
        } catch { XCTAssertTrue(error is BoneInferenceTransportError) }
    }
}

private actor AgnesDiscoveryTransport: BoneInferenceHTTPTransport {
    private(set) var url: URL?
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        url = request.url
        return .init(statusCode: status, data: Data(#"{"data":[{"id":"future-model"}]}"#.utf8))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse { throw BoneInferenceTransportError.invalidConfiguration }
}
