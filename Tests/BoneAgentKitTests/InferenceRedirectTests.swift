import Foundation
import XCTest
#if canImport(Network)
import Network
#endif
@testable import BoneAgentKit

final class InferenceRedirectTests: XCTestCase {
    func testRedirectRequiresExactOriginAndNoCredentials() {
        let base = URL(string: "https://api.example.test/v1")!
        for target in ["https://api.example.test/next", "https://api.example.test:443/next"] {
            XCTAssertTrue(BoneInferenceRedirectPolicy.allows(from: base, to: URL(string: target)))
        }
        for target in ["http://api.example.test/next", "https://other.test/next", "https://api.example.test:444/next",
                       "https://user:password@api.example.test/next", "file:///tmp/next"] {
            XCTAssertFalse(BoneInferenceRedirectPolicy.allows(from: base, to: URL(string: target)))
        }
    }

    #if canImport(Network)
    func testAllURLSessionPathsRejectCrossOriginRedirectsBeforeForwardingBody() async throws {
        let ready = expectation(description: "local servers ready")
        ready.expectedFulfillmentCount = 2
        let destination = try RedirectHTTPFixture { _ in "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok" }
        destination.start { ready.fulfill() }
        let source = try RedirectHTTPFixture { data in
            let line = String(decoding: data, as: UTF8.self)
            let status = line.contains("/302") ? 302 : line.contains("/308") ? 308 : 307
            return "HTTP/1.1 \(status) Redirect\r\nLocation: http://127.0.0.1:\(destination.port)/unexpected\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        source.start { ready.fulfill() }
        defer { source.stop(); destination.stop() }
        await fulfillment(of: [ready], timeout: 5)
        let transport = BoneInferenceURLSessionTransport(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(source.port)/start")!)
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic-private-body".utf8)
        request.setValue("synthetic-key", forHTTPHeaderField: "x-api-key")
        for status in [302, 307, 308] {
            request.url = URL(string: "http://127.0.0.1:\(source.port)/\(status)")!
            for mode in 0...2 {
                do {
                    switch mode {
                    case 0: _ = try await transport.send(request)
                    case 1: _ = try await transport.sendEventStream(request, options: .init(totalTimeout: 5))
                    default: for try await _ in transport.eventStream(request, options: .init(totalTimeout: 5)) {}
                    }
                    XCTFail("cross-origin redirect must fail")
                } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .invalidEndpoint) }
            }
        }
        XCTAssertEqual(source.requests, 9)
        XCTAssertEqual(destination.requests, 0, "No body or credentials may reach the other origin")
    }
    #endif
}

#if canImport(Network)
private final class RedirectHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "BoneAgentKit.redirect-test")
    private let reply: @Sendable (Data) -> String
    private let lock = NSLock()
    private var count = 0
    var port: UInt16 { listener.port!.rawValue }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    init(reply: @escaping @Sendable (Data) -> String) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.reply = reply
    }
    func start(ready: @escaping @Sendable () -> Void) {
        listener.stateUpdateHandler = { state in if case .ready = state { ready() } }
        listener.newConnectionHandler = { [self] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
                lock.lock(); count += 1; lock.unlock()
                connection.send(content: Data(reply(data ?? Data()).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
    }
    func stop() { listener.cancel() }
}
#endif
