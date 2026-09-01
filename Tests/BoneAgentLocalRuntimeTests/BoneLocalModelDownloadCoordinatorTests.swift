import CryptoKit
import XCTest
@testable import BoneAgentLocalRuntime

final class BoneLocalModelDownloadCoordinatorTests: XCTestCase {
    func testRejectsInsufficientDiskBeforeStartingTransport() async throws {
        let fixture = DownloadTransportFixture(scripts: [])
        let context = try makeContext(sources: [source(id: "one", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: fixture)

        do {
            _ = try await coordinator.download(
                context.model,
                environment: environment(availableDiskBytes: 2),
                policy: .init(diskSafetyMarginBytes: 1)
            )
            XCTFail("Expected insufficient disk error")
        } catch {
            XCTAssertEqual(
                error as? BoneLocalModelDownloadError,
                .insufficientDiskSpace(required: Int64(context.payload.count) + 1, available: 2)
            )
        }
        let sourceIDs = await fixture.startedSourceIDs()
        XCTAssertEqual(sourceIDs, [])
    }

    func testFallsBackAfterRetryableFailureThenInstallsVerifiedArtifact() async throws {
        let context = try makeContext(sources: [
            source(id: "backup", priority: 20),
            source(id: "primary", priority: 10),
        ])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let fixture = DownloadTransportFixture(scripts: [
            .failure(.server(statusCode: 503)),
            .success(context.payload),
        ])
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: fixture)

        let installedURL = try await coordinator.download(
            context.model,
            environment: environment(availableDiskBytes: 10_000),
            policy: .init(diskSafetyMarginBytes: 0)
        )

        let sourceIDs = await fixture.startedSourceIDs()
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(sourceIDs, ["primary", "backup"])
        XCTAssertEqual(try Data(contentsOf: installedURL), context.payload)
        XCTAssertEqual(state, .installed(installedURL))
    }

    func testPauseResumeAndCancelDelegateToActiveOperation() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let transport = PausableTransportFixture(payload: context.payload)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let model = context.model
        let downloadEnvironment = environment(availableDiskBytes: 10_000)
        let download = Task {
            try await coordinator.download(
                model,
                environment: downloadEnvironment,
                policy: .init(diskSafetyMarginBytes: 0)
            )
        }
        await transport.waitUntilStarted()

        let resumeData = try await coordinator.pause(modelID: context.model.id)
        XCTAssertEqual(resumeData, Data("resume-data".utf8))
        let pausedState = await coordinator.state(for: context.model.id)
        XCTAssertEqual(pausedState, .paused(sourceID: "primary", resumeData: resumeData))
        _ = await download.result

        let installedURL = try await coordinator.resume(
            context.model,
            environment: environment(availableDiskBytes: 10_000),
            policy: .init(diskSafetyMarginBytes: 0)
        )
        let receivedResumeData = await transport.receivedResumeData()
        XCTAssertEqual(try Data(contentsOf: installedURL), context.payload)
        XCTAssertEqual(receivedResumeData, resumeData)

        let secondTransport = PausableTransportFixture(payload: context.payload)
        let secondCoordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: secondTransport)
        let secondDownload = Task {
            try await secondCoordinator.download(
                model,
                environment: downloadEnvironment,
                policy: .init(diskSafetyMarginBytes: 0)
            )
        }
        await secondTransport.waitUntilStarted()
        await secondCoordinator.cancel(modelID: context.model.id)
        let cancelledState = await secondCoordinator.state(for: context.model.id)
        XCTAssertEqual(cancelledState, .cancelled)
        _ = await secondDownload.result
    }

    func testDoesNotFallbackForClientOrIntegrityFailure() async throws {
        for script in [DownloadScript.failure(.client(statusCode: 404)), .success(Data("wrong".utf8))] {
            let context = try makeContext(sources: [
                source(id: "primary", priority: 1),
                source(id: "backup", priority: 2),
            ])
            defer { try? FileManager.default.removeItem(at: context.root) }
            let fixture = DownloadTransportFixture(scripts: [script, .success(context.payload)])
            let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: fixture)

            do {
                _ = try await coordinator.download(
                    context.model,
                    environment: environment(availableDiskBytes: 10_000),
                    policy: .init(diskSafetyMarginBytes: 0)
                )
                XCTFail("Expected terminal failure")
            } catch {}
            let sourceIDs = await fixture.startedSourceIDs()
            XCTAssertEqual(sourceIDs, ["primary"])
        }
    }

    private func makeContext(sources: [BoneLocalModelDownloadSource]) throws -> (
        root: URL,
        store: BoneLocalModelStore,
        model: BoneLocalModelDescriptor,
        payload: Data
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let payload = Data("verified-model-payload".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let model = BoneLocalModelDescriptor(
            id: "test-model",
            displayName: "Test",
            family: "Test",
            format: .gguf,
            parameterCount: 1_000,
            quantization: "Q4",
            minimumMemoryBytes: 1,
            recommendedContextTokens: 512,
            minimumRuntimeVersion: 1,
            contextLimits: try .init(
                contextWindowTokens: 1_024,
                maximumInputTokens: 768,
                maximumOutputTokens: 256,
                source: .official,
                verifiedAt: "2026-09-01",
                documentationURL: URL(string: "https://example.com/model")!
            ),
            artifact: .init(
                fileName: "model.gguf",
                expectedByteCount: Int64(payload.count),
                sha256: hash,
                sources: sources
            ),
            license: .init(
                name: "Test",
                url: URL(string: "https://example.com/license")!,
                modelCardURL: URL(string: "https://example.com/model")!
            )
        )
        return (root, try BoneLocalModelStore(rootURL: root.appendingPathComponent("models")), model, payload)
    }

    private func source(id: String, priority: Int) -> BoneLocalModelDownloadSource {
        .init(
            id: id,
            url: URL(string: "https://models.example.com/\(id).gguf")!,
            allowedHosts: ["models.example.com"],
            priority: priority
        )
    }

    private func environment(availableDiskBytes: Int64) -> BoneLocalRuntimeEnvironment {
        .init(
            physicalMemoryBytes: 10_000,
            availableDiskBytes: availableDiskBytes,
            activeProcessorCount: 4,
            isSimulator: false,
            isLowPowerModeEnabled: false,
            thermalState: .nominal
        )
    }
}

private enum DownloadScript: Sendable {
    case success(Data)
    case failure(BoneLocalModelDownloadTransportFailure)
}

private actor DownloadTransportFixture: BoneLocalModelDownloadTransport {
    private var scripts: [DownloadScript]
    private var sourceIDs: [String] = []

    init(scripts: [DownloadScript]) { self.scripts = scripts }

    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        sourceIDs.append(request.source.id)
        let script = scripts.removeFirst()
        return DownloadOperationFixture(script: script, destinationURL: request.destinationURL)
    }

    func startedSourceIDs() -> [String] { sourceIDs }
}

private actor PausableTransportFixture: BoneLocalModelDownloadTransport {
    private let payload: Data
    private var startCount = 0
    private var resumeData: Data?

    init(payload: Data) { self.payload = payload }

    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        startCount += 1
        resumeData = request.resumeData
        if request.resumeData != nil {
            return DownloadOperationFixture(script: .success(payload), destinationURL: request.destinationURL)
        }
        return PausableOperationFixture()
    }

    func waitUntilStarted() async {
        while startCount == 0 { await Task.yield() }
    }

    func receivedResumeData() -> Data? { resumeData }
}

private final class PausableOperationFixture: @unchecked Sendable, BoneLocalModelDownloadOperation {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.Continuation?

    func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
    }

    func pause() async throws -> Data {
        let data = Data("resume-data".utf8)
        finish(with: .cancelled(resumeData: data))
        return data
    }

    func cancel() async { finish(with: .cancelled(resumeData: nil)) }

    private func finish(with error: BoneLocalModelDownloadTransportFailure) {
        lock.lock()
        let continuation = continuation
        lock.unlock()
        continuation?.finish(throwing: error)
    }
}

private struct DownloadOperationFixture: BoneLocalModelDownloadOperation {
    let script: DownloadScript
    let destinationURL: URL

    func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                switch script {
                case .success(let data):
                    try FileManager.default.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try data.write(to: destinationURL)
                    continuation.yield(.progress(.init(
                        downloadedBytes: Int64(data.count),
                        expectedBytes: Int64(data.count)
                    )))
                    continuation.yield(.completed(destinationURL))
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func pause() async throws -> Data { Data("resume".utf8) }
    func cancel() async {}
}
