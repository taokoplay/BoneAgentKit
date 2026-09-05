import XCTest
@testable import BoneAgentLocalModels

final class BoneURLSessionLocalModelDownloadTransportTests: XCTestCase {
    func testDownloadsResponseToRequestedDestination() async throws {
        let payload = Data("downloaded-model".utf8)
        let protocolFixture = URLProtocolFixture { request in
            XCTAssertEqual(request.url?.host, "models.example.com")
            return (HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(payload.count)"]
            )!, payload)
        }
        let transport = BoneURLSessionLocalModelDownloadTransport(
            configuration: protocolFixture.configuration
        )
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("model.download")
        let operation = try await transport.start(request(destinationURL: destination))

        var completedURL: URL?
        for try await event in operation.events() {
            if case .completed(let url) = event { completedURL = url }
        }

        XCTAssertEqual(completedURL, destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
    }

    func testClassifiesHTTPFailures() async throws {
        for (status, expected) in [
            (404, BoneLocalModelDownloadTransportFailure.client(statusCode: 404)),
            (503, BoneLocalModelDownloadTransportFailure.server(statusCode: 503)),
        ] {
            let fixture = URLProtocolFixture { request in
                (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
            }
            let transport = BoneURLSessionLocalModelDownloadTransport(configuration: fixture.configuration)
            let operation = try await transport.start(request(destinationURL: temporaryDirectory().appendingPathComponent("model")))
            do {
                for try await _ in operation.events() {}
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertEqual(error as? BoneLocalModelDownloadTransportFailure, expected)
            }
        }
    }

    func testRejectsOversizedChunkedBody() async throws {
        let fixture = URLProtocolFixture { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, Data(repeating: 1, count: 64))
        }
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("oversized")
        let operation = try await BoneURLSessionLocalModelDownloadTransport(configuration: fixture.configuration).start(request(destinationURL: destination))
        do {
            for try await _ in operation.events() {}
            XCTFail("oversized body accepted")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadTransportFailure, .invalidResponse(statusCode: nil)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testConsumerCancellationStopsURLProtocol() async throws {
        let started = expectation(description: "URLProtocol started")
        let stopped = expectation(description: "URLProtocol stopped")
        HoldingURLProtocol.onStart = { started.fulfill() }
        HoldingURLProtocol.onStop = { stopped.fulfill() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldingURLProtocol.self]
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = try await BoneURLSessionLocalModelDownloadTransport(configuration: config).start(request(destinationURL: root.appendingPathComponent("cancel")))
        let consumer = Task { for try await _ in operation.events() {} }
        await fulfillment(of: [started], timeout: 2)
        consumer.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        _ = await consumer.result
    }

    func testCancelBeforeEventsDoesNotStartURLProtocol() async throws {
        let started = expectation(description: "must not start")
        started.isInverted = true
        HoldingURLProtocol.onStart = { started.fulfill() }
        HoldingURLProtocol.onStop = {}
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HoldingURLProtocol.self]
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let operation = try await BoneURLSessionLocalModelDownloadTransport(configuration: config).start(request(destinationURL: root.appendingPathComponent("cancel")))
        await operation.cancel()
        do { for try await _ in operation.events() {} ; XCTFail("expected cancellation") } catch {}
        await fulfillment(of: [started], timeout: 0.05)
    }

    func testOversizedProgressStopsLoadingBeforeEOF() async throws {
        let stopped = expectation(description: "oversized response stopped before EOF")
        OversizedHoldingURLProtocol.onStop = { stopped.fulfill() }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OversizedHoldingURLProtocol.self]
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("oversized-stream")
        let operation = try await BoneURLSessionLocalModelDownloadTransport(configuration: config).start(request(destinationURL: destination))
        let consumer = Task {
            do { for try await _ in operation.events() {}; XCTFail("expected limit failure") }
            catch { XCTAssertEqual(error as? BoneLocalModelDownloadTransportFailure, .invalidResponse(statusCode: nil)) }
        }
        await fulfillment(of: [stopped], timeout: 3)
        // Also bound cleanup if a regression stops enforcing progress limits.
        await operation.cancel()
        await consumer.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testResumeOffsetAndProgressEnforceManifestLimit() async throws {
        for useOffset in [true, false] {
            let started = expectation(description: "started")
            let stopped = expectation(description: "resumed oversize cancelled")
            HoldingURLProtocol.onStart = { started.fulfill() }
            HoldingURLProtocol.onStop = { stopped.fulfill() }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HoldingURLProtocol.self]
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }
            let operation = try await BoneURLSessionLocalModelDownloadTransport(configuration: config).start(request(destinationURL: root.appendingPathComponent("resume")))
            let consumer = Task {
                do { for try await _ in operation.events() {}; XCTFail("expected limit failure") }
                catch { XCTAssertEqual(error as? BoneLocalModelDownloadTransportFailure, .invalidResponse(statusCode: nil)) }
            }
            await fulfillment(of: [started], timeout: 2)
            // Deterministically inject the delegate callback used for resumed downloads;
            // OS-generated opaque resume data is deliberately not fabricated.
            let delegate = try XCTUnwrap(operation as? URLSessionDownloadDelegate)
            let session = URLSession(configuration: config)
            let task = session.downloadTask(with: URL(string: "https://models.example.com/unused")!)
            if useOffset {
                delegate.urlSession?(session, downloadTask: task, didResumeAtOffset: 17, expectedTotalBytes: -1)
            } else {
                delegate.urlSession?(session, downloadTask: task, didWriteData: 1, totalBytesWritten: 17, totalBytesExpectedToWrite: -1)
            }
            await fulfillment(of: [stopped], timeout: 2)
            await consumer.value
            session.invalidateAndCancel()
        }
    }

    private func request(destinationURL: URL) -> BoneLocalModelDownloadRequest {
        .init(
            modelID: "model",
            source: .init(
                id: "official",
                url: URL(string: "https://models.example.com/model.gguf")!,
                allowedHosts: ["models.example.com"],
                priority: 1
            ),
            destinationURL: destinationURL,
            expectedByteCount: 16,
            policy: .init(diskSafetyMarginBytes: 0)
        )
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class URLProtocolFixture: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    private let handler: Handler

    init(handler: @escaping Handler) { self.handler = handler }

    var configuration: URLSessionConfiguration {
        TestURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        return configuration
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) static var handler: URLProtocolFixture.Handler?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class HoldingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var onStart: (@Sendable () -> Void)?
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.onStart?() }
    override func stopLoading() { Self.onStop?() }
}

private final class OversizedHoldingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 65_536))
        // Intentionally no EOF: the download delegate must cancel from progress.
    }
    override func stopLoading() { Self.onStop?() }
}
