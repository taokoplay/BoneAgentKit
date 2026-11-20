import Foundation
import Testing
import BoneAgentTools
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

@Suite(.serialized)
struct SearchPOSTTransportTests {
    @Test func boundedPostReceivesOneResponseWithoutRetry() async throws {
        SearchPOSTProtocol.reset(bytes: 4)
        let response = try await transport().send(request: request(), maximumResponseBytes: 16)
        #expect(response.statusCode == 200 && response.body.count == 4)
        #expect(SearchPOSTProtocol.callCount == 1)
    }
    @Test func responseIsStoppedDuringReceivingAtTheByteBoundary() async throws {
        SearchPOSTProtocol.reset(bytes: 32)
        await #expect(throws: BoneWebError.responseTooLarge) {
            try await transport().send(request: request(), maximumResponseBytes: 16)
        }
        #expect(SearchPOSTProtocol.callCount == 1)
    }
    @Test func unexpectedDestinationIsRejectedBeforeDispatch() async throws {
        SearchPOSTProtocol.reset(bytes: 4)
        var proposed = request()
        proposed.url = URL(string: "https://example.com/search")
        await #expect(throws: BoneWebError.invalidConfiguration) {
            try await transport().send(request: proposed, maximumResponseBytes: 16)
        }
        #expect(SearchPOSTProtocol.callCount == 0)
    }
    private func request() -> URLRequest {
        var request = URLRequest(url: DemoDeepSeekSearchClient.endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data(#"{"query":"Swift","count":1,"need_content":false}"#.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private func transport() -> DemoSearchPOSTTransport {
        DemoSearchPOSTTransport {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SearchPOSTProtocol.self]
            return configuration
        }
    }
}

private final class SearchPOSTProtocol: URLProtocol, @unchecked Sendable {
    private struct State: Sendable { var bytes = 0; var calls = 0 }
    private final class Storage: @unchecked Sendable {
        private var value = State()
        private let lock = NSLock()
        func withLock<Result>(_ action: (inout State) -> Result) -> Result {
            lock.lock(); defer { lock.unlock() }
            return action(&value)
        }
    }
    private static let state = Storage()
    static var callCount: Int { state.withLock { $0.calls } }
    static func reset(bytes: Int) { state.withLock { $0 = .init(bytes: bytes, calls: 0) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.deepseek.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.state.withLock { state in state.calls += 1; return state.bytes }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 65, count: count))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
