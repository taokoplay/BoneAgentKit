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
