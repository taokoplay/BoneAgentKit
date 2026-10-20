import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import BoneAgentKit

final class EventStreamTransportTests: XCTestCase {
    func testForbiddenCaptureReadsBodyWithoutProducingSSEEvents() async throws {
        let records = FailureCaptureRecorder()
        let transport = failureTransport(body: Data("<html>denied</html>".utf8), capture: .init { records.append($0) })
        var count = 0
        do {
            for try await _ in transport.eventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init()) { count += 1 }
            XCTFail("Expected HTTP rejection")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
        XCTAssertEqual(count, 0)
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.first?.body, Data("<html>denied</html>".utf8))
        XCTAssertEqual(records.values.first?.completion, .complete)
        XCTAssertEqual(records.values.first?.headers, ["content-type": "text/html", "cf-ray": "fixture-ray"])
    }

    func testForbiddenCaptureStopsAtByteLimitAndTimeLimit() async throws {
        for timeLimited in [false, true] {
            let records = FailureCaptureRecorder()
            let transport = failureTransport(body: Data("not SSE at all".utf8), finishes: !timeLimited,
                capture: .init(maximumBodyBytes: timeLimited ? 100 : 4, maximumDuration: 0.03) { records.append($0) })
            do {
                _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init(firstEventTimeout: 5, idleTimeout: 5))
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
            XCTAssertEqual(records.values.count, 1)
            XCTAssertEqual(records.values.first?.body.count, timeLimited ? 14 : 4)
            XCTAssertEqual(records.values.first?.completion, timeLimited ? .timeLimit : .byteLimit)
        }
    }

    func testForbiddenCaptureHonorsTotalDeadline() async throws {
        let records = FailureCaptureRecorder()
        let transport = failureTransport(body: Data("partial".utf8), finishes: false,
            capture: .init(maximumDuration: 5) { records.append($0) })
        do {
            _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init(totalTimeout: 0.03))
            XCTFail("Expected deadline")
        } catch { XCTAssertTrue(error is BoneInferenceStreamDeadlineExceeded) }
        XCTAssertEqual(records.values.first?.completion, .interrupted)
        XCTAssertEqual(records.values.first?.body, Data("partial".utf8))
    }

    func testForbiddenCaptureCancellationEmitsInterruptedOnlyOnce() {
        // Deliver delegates deterministically: URLProtocol didReceive is queued and may not
        // have reached the bridge when the consumer cancels. Consumer cancellation itself
        // is covered by testCancellingEventConsumerCancelsHTTPTask.
        let records = FailureCaptureRecorder()
        let request = URLRequest(url: URL(string: "https://example.com/events")!)
        let bridge = BoneInferenceEventStreamSessionBridge(configuration: .ephemeral, request: request,
            options: .init(), failureCapture: .init { records.append($0) })
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
        bridge.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        bridge.urlSession(session, dataTask: task, didReceive: Data("private-partial".utf8))
        bridge.cancel()
        bridge.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.first?.completion, .interrupted)
        XCTAssertEqual(records.values.first?.body, Data("private-partial".utf8))
    }

    func testForbiddenCaptureNetworkInterruptionPreservesKnownHTTPStatus() async throws {
        let records = FailureCaptureRecorder()
        let request = URLRequest(url: URL(string: "https://example.com/events")!)
        let releaseNetwork = AsyncGate()
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(handler: { client, instance in
            await releaseNetwork.wait()
            client.urlProtocolDidFinishLoading(instance)
        })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        let bridge = BoneInferenceEventStreamSessionBridge(configuration: configuration, request: request,
            options: .init(), failureCapture: .init { records.append($0) })
        let stream = bridge.eventStream()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
        bridge.urlSession(session, dataTask: task, didReceive: response) { XCTAssertEqual($0, .allow) }
        bridge.urlSession(session, dataTask: task, didReceive: Data("partial".utf8))
        bridge.urlSession(session, task: task, didCompleteWithError: URLError(.networkConnectionLost))
        do {
            for try await _ in stream { XCTFail("No SSE events on HTTP rejection") }
            XCTFail("Expected HTTP rejection")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
        await releaseNetwork.open()
        XCTAssertEqual(records.values.count, 1)
        XCTAssertEqual(records.values.first?.completion, .interrupted)
        XCTAssertEqual(records.values.first?.body, Data("partial".utf8))
    }

    func testDisabledForbiddenCaptureStillRejectsImmediately() async throws {
        let transport = failureTransport(body: Data(), finishes: false, capture: .init())
        do {
            _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init(totalTimeout: 0.5))
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
    }

    func testNonStreamingURLSessionCaptureKeepsResponseAndOverflowError() async throws {
        for limit in [4, 100] {
            let records = FailureCaptureRecorder()
            let fixture = StreamingURLProtocolFixture()
            fixture.configure(handler: { client, instance in
                let response = HTTPURLResponse(url: instance.request.url!, statusCode: 403, httpVersion: nil, headerFields: [:])!
                client.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(instance, didLoad: Data("forbidden".utf8))
                client.urlProtocolDidFinishLoading(instance)
            })
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StreamingURLProtocol.self]
            StreamingURLProtocol.install(fixture)
            let transport = BoneInferenceURLSessionTransport(configuration: config, maximumResponseByteCount: limit,
                failureCapture: .init(maximumBodyBytes: 6) { records.append($0) })
            do {
                let response = try await transport.send(URLRequest(url: URL(string: "https://example.com")!))
                XCTAssertEqual(limit, 100)
                XCTAssertEqual(response.statusCode, 403)
                XCTAssertEqual(response.data, Data("forbidden".utf8))
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .responseTooLarge); XCTAssertEqual(limit, 4) }
            XCTAssertEqual(records.values.count, 1)
            XCTAssertEqual(records.values.first?.body, Data("forbid".utf8))
            XCTAssertEqual(records.values.first?.completion, .byteLimit)
        }
    }

    func testForbiddenCaptureRespectsStreamBudgetAndExactEOF() async throws {
        for (body, cap, budget, completion) in [
            ("", 0, 100, BoneInferenceFailureResponse.Completion.complete),
            ("four", 4, 100, .complete),
            ("five!", 100, 4, .byteLimit)
        ] {
            let records = FailureCaptureRecorder()
            let transport = failureTransport(body: Data(body.utf8), capture: .init(maximumBodyBytes: cap) { records.append($0) })
            do {
                _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com")!), options: .init(maximumBytes: budget))
                XCTFail("Expected rejection")
            } catch { XCTAssertEqual(error as? BoneInferenceTransportError, .httpStatus(403)) }
            XCTAssertEqual(records.values.first?.completion, completion)
            XCTAssertLessThanOrEqual(records.values.first?.body.count ?? Int.max, min(cap, budget))
        }
    }

    private func failureTransport(body: Data, finishes: Bool = true, capture: BoneInferenceFailureCapture) -> BoneInferenceURLSessionTransport {
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(handler: { client, instance in
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 403, httpVersion: nil,
                headerFields: ["Content-Type": "text/html", "CF-Ray": "fixture-ray", "Set-Cookie": "secret-cookie"])!
            client.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: body)
            if finishes { client.urlProtocolDidFinishLoading(instance) }
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        return BoneInferenceURLSessionTransport(configuration: config, failureCapture: capture)
    }

    func testFramerAcceptsCRLFCRAndLFAtEveryChunkBoundary() throws {
        for delimiter in ["\r", "\n", "\r\n"] {
            let bytes = Array(("data: 你好" + delimiter + delimiter + "data: done" + delimiter + delimiter).utf8)
            for split in 0...bytes.count {
                var framer = BoneInferenceEventStreamFramer(maximumBytes: bytes.count)
                var events = try framer.append(Data(bytes.prefix(split)))
                events += try framer.append(Data(bytes.dropFirst(split)))
                events += try framer.finish()
                XCTAssertEqual(events, [.init(data: "你好"), .init(data: "done")])
            }
        }
    }

    func testTotalDeadlineStopsOpenStream() async throws {
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(handler: { client, instance in
            let response = HTTPURLResponse(url: instance.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            client.urlProtocol(instance, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(instance, didLoad: Data("data: first\n\n".utf8))
            // Keep connection open: idle limit is deliberately longer than total limit.
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        let transport = BoneInferenceURLSessionTransport(configuration: config)
        do {
            _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init(firstEventTimeout: 5, idleTimeout: 5, totalTimeout: 0.05))
            XCTFail("Expected total deadline")
        } catch { XCTAssertTrue(error is BoneInferenceStreamDeadlineExceeded) }
    }

    func testPastHostDeadlineRejectsBeforeNetwork() async throws {
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(handler: { _, _ in XCTFail("Must not start expired request") })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StreamingURLProtocol.self]
        StreamingURLProtocol.install(fixture)
        let transport = BoneInferenceURLSessionTransport(configuration: config)
        do {
            _ = try await transport.sendEventStream(URLRequest(url: URL(string: "https://example.com/events")!), options: .init(deadlineUptime: ProcessInfo.processInfo.systemUptime - 1))
            XCTFail("Expected expired deadline")
        } catch { XCTAssertTrue(error is BoneInferenceStreamDeadlineExceeded) }
    }

    func testFramerRejectsUnterminatedDataIncludingNewlineWithoutBlankLine() throws {
        for suffix in ["data: [DONE]", "data: [DONE]\n", "data: [DONE]\r\n"] {
            var framer = BoneInferenceEventStreamFramer(maximumBytes: 4096)
            XCTAssertEqual(try framer.append(Data(suffix.utf8)), [])
            XCTAssertThrowsError(try framer.finish()) {
                XCTAssertEqual($0 as? BoneInferenceTransportError, .invalidResponse)
            }
        }
    }

    func testFramerPreservesSplitUTF8CRLFMultilineAndIgnoresEmptyFrames() throws {
        let input = "\r\n: heartbeat\r\n\r\nevent: message\r\nid: 1\r\ndata: 你好🐟\r\ndata: second\r\n\r\n\r\nevent: ping\r\n\r\ndata:\n\n"
        var framer = BoneInferenceEventStreamFramer(maximumBytes: input.utf8.count)
        var events: [BoneInferenceEventStreamEvent] = []
        for byte in input.utf8 { events += try framer.append(Data([byte])) }
        events += try framer.finish()
        XCTAssertEqual(events, [.init(event: "message", id: "1", data: "你好🐟\nsecond"), .init(data: "")])
    }

    func testFramerCumulativeByteLimitAndInvalidUTF8() throws {
        var framer = BoneInferenceEventStreamFramer(maximumBytes: 8)
        XCTAssertEqual(try framer.append(Data("data:x\n\n".utf8)), [.init(data: "x")])
        XCTAssertThrowsError(try framer.append(Data([10]))) {
            XCTAssertEqual($0 as? BoneInferenceTransportError, .responseTooLarge)
        }
        var invalid = BoneInferenceEventStreamFramer(maximumBytes: 10)
        XCTAssertThrowsError(try invalid.append(Data([0xFF, 10]))) {
            XCTAssertEqual($0 as? BoneInferenceTransportError, .invalidResponse)
        }
    }

    func testHTTPStreamRejectsUnframedEOFAndByteOverflow() async throws {
        for (body, limit, expected) in [
            ("data: [DONE]", 4096, BoneInferenceTransportError.invalidResponse),
            ("data: too large\n\n", 4, BoneInferenceTransportError.responseTooLarge)
        ] {
            let fixture = StreamingURLProtocolFixture()
            fixture.configure(handler: { client, protocolInstance in
                let response = HTTPURLResponse(url: protocolInstance.request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(protocolInstance, didLoad: Data(body.utf8))
                client.urlProtocolDidFinishLoading(protocolInstance)
            })
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StreamingURLProtocol.self]
            StreamingURLProtocol.install(fixture)
            let transport = BoneInferenceURLSessionTransport(configuration: configuration)
            do {
                for try await _ in transport.eventStream(
                    URLRequest(url: URL(string: "https://example.com/events")!),
                    options: .init(firstEventTimeout: 2, idleTimeout: 2, maximumBytes: limit)
                ) {}
                XCTFail("Expected \(expected)")
            } catch {
                XCTAssertEqual(error as? BoneInferenceTransportError, expected)
            }
        }
    }

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
        let started = expectation(description: "URL protocol started")
        let fixture = StreamingURLProtocolFixture()
        fixture.configure(onStop: { stopped.fulfill() }, handler: { client, protocolInstance in
            let response = HTTPURLResponse(
                url: protocolInstance.request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client.urlProtocol(protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            started.fulfill()
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
        await fulfillment(of: [started], timeout: 1)
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
