import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class EventStreamTransportTests: XCTestCase {
    func testURLSessionTransportYieldsSSEBeforeNetworkCompletion() async throws {
        let firstChunkSent = expectation(description: "first chunk sent")
        let allowCompletion = AsyncGate()
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(handler: { client, protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(protocolInstance, didLoad: Data("data: {\"type\":\"ping\"}\n\n".utf8))
            firstChunkSent.fulfill()
            await allowCompletion.wait()
            client.urlProtocolDidFinishLoading(protocolInstance)
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        let transport = BoneInferenceURLSessionTransport(configuration: configuration)
        let stream = transport.eventStream(
            URLRequest(url: URL(string: "https://example.com/events")!),
            options: .init(firstEventTimeout: 2, idleTimeout: 2)
        )

        var iterator = stream.makeAsyncIterator()
        await fulfillment(of: [firstChunkSent], timeout: 1)
        let first = try await iterator.next()
        XCTAssertEqual(first?.data, #"{"type":"ping"}"#)
        let wasOpened = await allowCompletion.wasOpened
        XCTAssertFalse(wasOpened)
        await allowCompletion.open()
        let terminal = try await iterator.next()
        XCTAssertNil(terminal)
    }

    func testCancellingEventConsumerCancelsHTTPTask() async throws {
        let stopped = expectation(description: "URL protocol stopped")
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(onStop: { stopped.fulfill() }, handler: { client, protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        let transport = BoneInferenceURLSessionTransport(configuration: configuration)
        let task = Task {
            for try await _ in transport.eventStream(
                URLRequest(url: URL(string: "https://example.com/events")!),
                options: .init(firstEventTimeout: 30, idleTimeout: 30)
            ) {}
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        _ = await task.result
        await fulfillment(of: [stopped], timeout: 1)
    }
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var wasOpened = false

    func wait() async {
        if wasOpened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        wasOpened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class StreamingURLProtocolFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLProtocolClient, StreamingURLProtocol) async -> Void

    private let lock = NSLock()
    private var handler: Handler?
    private var onStop: (@Sendable () -> Void)?

    func configure(
        onStop: (@Sendable () -> Void)? = nil,
        handler: @escaping Handler
    ) {
        lock.withLock {
            self.handler = handler
            self.onStop = onStop
        }
    }

    func snapshot() -> (Handler?, (@Sendable () -> Void)?) {
        lock.withLock { (handler, onStop) }
    }
}

private struct UncheckedSendableReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private final class StreamingURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = StreamingURLProtocolFixture.Handler
    private static let fixtureLock = NSLock()
    nonisolated(unsafe) private static var fixture: StreamingURLProtocolFixture?
    private var loadingTask: Task<Void, Never>?
    private var onStop: (@Sendable () -> Void)?

    static func install(_ fixture: StreamingURLProtocolFixture) {
        fixtureLock.withLock { self.fixture = fixture }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let fixture = Self.fixtureLock.withLock { Self.fixture }
        guard let client, let fixture else { return }
        let (handler, onStop) = fixture.snapshot()
        guard let handler else { return }
        self.onStop = onStop
        let protocolInstance = UncheckedSendableReference(self)
        loadingTask = Task { await handler(client, protocolInstance.value) }
    }

    override func stopLoading() {
        loadingTask?.cancel()
        onStop?()
    }
}
