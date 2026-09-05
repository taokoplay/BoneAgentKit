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
                .insufficientDiskSpace(required: Int64(context.payload.count) * 2 + 1, available: 2)
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

    func testStartGateRejectsDuplicateAndCancelsLateOperation() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let transport = StartGateTransport(payload: context.payload)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let env = environment(availableDiskBytes: 10_000)
        let first = Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }
        await transport.waitForStart()
        do {
            _ = try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0))
            XCTFail("duplicate accepted")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadError, .alreadyActive) }
        await coordinator.cancel(modelID: context.model.id)
        await transport.release()
        if case .success = await first.result { XCTFail("late start installed after cancel") }
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .cancelled)
        let cancelled = await transport.wasCancelled()
        XCTAssertTrue(cancelled)
    }

    func testOldCancelAndDeferCannotOverwriteNewInstalledState() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let old = CancelGateOperation()
        let transport = ReplacementTransport(old: old, payload: context.payload)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let env = environment(availableDiskBytes: 10_000)
        let first = Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }
        await old.waitForEvents()
        let cancellation = Task { await coordinator.cancel(modelID: context.model.id) }
        await old.waitForCancel()
        let installed = try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0))
        await old.releaseCancel()
        await cancellation.value
        _ = await first.result
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .installed(installed))
        let paths = await transport.destinations
        XCTAssertEqual(Set(paths).count, 2)
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }

    func testTaskCancellationWhileStartSuspendedCancelsLateHandle() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let transport = StartGateTransport(payload: context.payload)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let env = environment(availableDiskBytes: 10_000)
        let task = Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }
        await transport.waitForStart()
        task.cancel()
        await transport.release()
        if case .success = await task.result { XCTFail("cancelled task installed") }
        let cancelled = await transport.wasCancelled()
        XCTAssertTrue(cancelled)
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .cancelled)
    }

    func testProgressLimitCancelsAndDoesNotDeleteExternalCompletionFile() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let external = context.root.appendingPathComponent("external")
        try context.payload.write(to: external)
        let operation = OversizeOperation(external: external)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: SingleOperationTransport(operation: operation))
        do {
            _ = try await coordinator.download(context.model, environment: environment(availableDiskBytes: 10_000), policy: .init(diskSafetyMarginBytes: 0))
            XCTFail("oversized progress accepted")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadError, .invalidResponse(statusCode: nil)) }
        let cancelled = await operation.cancelled
        XCTAssertTrue(cancelled)
        XCTAssertEqual(try Data(contentsOf: external), context.payload)
    }

    func testExternalCompletedFileIsRejectedWithoutDeletion() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let external = context.root.appendingPathComponent("external")
        try context.payload.write(to: external)
        let operation = OversizeOperation(external: external, emitsOversize: false)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: SingleOperationTransport(operation: operation))
        do {
            _ = try await coordinator.download(context.model, environment: environment(availableDiskBytes: 10_000), policy: .init(diskSafetyMarginBytes: 0))
            XCTFail("external completion accepted")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadError, .invalidResponse(statusCode: nil)) }
        XCTAssertEqual(try Data(contentsOf: external), context.payload)
    }

    func testCancelWinsOverLatePauseCallbackAndProgress() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let operation = PauseGateOperation()
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: SingleOperationTransport(operation: operation))
        let env = environment(availableDiskBytes: 10_000)
        let download = Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }
        await operation.waitForEvents()
        let pause = Task { try await coordinator.pause(modelID: context.model.id) }
        await operation.waitForPause()
        await coordinator.cancel(modelID: context.model.id)
        await operation.releasePause()
        if case .success = await pause.result { XCTFail("late pause beat cancel") }
        _ = await download.result
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .cancelled)
    }

    func testDiskBudgetOverflowFailsClosed() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let fixture = DownloadTransportFixture(scripts: [])
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: fixture)
        do {
            _ = try await coordinator.download(context.model, environment: environment(availableDiskBytes: .max), policy: .init(diskSafetyMarginBytes: .max))
            XCTFail("overflow accepted")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadError, .insufficientDiskSpace(required: .max, available: .max)) }
    }

    func testReviewPauseWaitsForLastDestinationWriteBeforeCleanup() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let operation = PauseGateOperation()
        let transport = TailWriteTransport(operation: operation)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let env = environment(availableDiskBytes: 10_000)
        let premature = expectation(description: "download must wait for pause quiescence")
        premature.isInverted = true
        let download = Task {
            let result = await Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }.result
            premature.fulfill()
            return result
        }
        await operation.waitForEvents()
        let pause = Task { try await coordinator.pause(modelID: context.model.id) }
        await operation.waitForPause()
        operation.continuation.yield(.progress(.init(downloadedBytes: 1, expectedBytes: 21)))
        await fulfillment(of: [premature], timeout: 0.05)
        let capturedDestination = await transport.destination()
        let destination = try XCTUnwrap(capturedDestination)
        try Data("last write before pause returns".utf8).write(to: destination)
        await operation.releasePause()
        _ = try await pause.value
        _ = await download.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testReviewResumeBudgetFailurePreservesResumeData() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let transport = PausableTransportFixture(payload: context.payload)
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: transport)
        let env = environment(availableDiskBytes: 10_000)
        let download = Task { try await coordinator.download(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0)) }
        await transport.waitUntilStarted()
        let data = try await coordinator.pause(modelID: context.model.id)
        _ = await download.result
        do {
            _ = try await coordinator.resume(context.model, environment: environment(availableDiskBytes: 0), policy: .init(diskSafetyMarginBytes: 0))
            XCTFail("budget should fail")
        } catch {}
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .paused(sourceID: "primary", resumeData: data))
        let installed = try await coordinator.resume(context.model, environment: env, policy: .init(diskSafetyMarginBytes: 0))
        XCTAssertEqual(try Data(contentsOf: installed), context.payload)
    }

    func testReviewFallbackUsesLastUnknownError() async throws {
        let context = try makeContext(sources: [source(id: "primary", priority: 1), source(id: "backup", priority: 2)])
        defer { try? FileManager.default.removeItem(at: context.root) }
        let coordinator = BoneLocalModelDownloadCoordinator(store: context.store, transport: UnknownFallbackTransport())
        do {
            _ = try await coordinator.download(context.model, environment: environment(availableDiskBytes: 10_000), policy: .init(diskSafetyMarginBytes: 0))
            XCTFail("expected failure")
        } catch { XCTAssertEqual(error as? BoneLocalModelDownloadError, .transportFailure) }
        let state = await coordinator.state(for: context.model.id)
        XCTAssertEqual(state, .failed(.transportFailure))
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

private actor StartGateTransport: BoneLocalModelDownloadTransport {
    let payload: Data
    var gate: CheckedContinuation<Void, Never>?
    var entered = false
    var operation: LateOperation?
    init(payload: Data) { self.payload = payload }
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        if entered { throw BoneLocalModelDownloadTransportFailure.other }
        entered = true
        await withCheckedContinuation { gate = $0 }
        let op = LateOperation(payload: payload, url: request.destinationURL)
        operation = op
        return op
    }
    func waitForStart() async { while gate == nil { await Task.yield() } }
    func release() { gate?.resume(); gate = nil }
    func wasCancelled() async -> Bool { await operation?.cancelled ?? false }
}
private actor LateOperation: BoneLocalModelDownloadOperation {
    let payload: Data
    let url: URL
    var cancelled = false
    init(payload: Data, url: URL) { self.payload = payload; self.url = url }
    nonisolated func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        AsyncThrowingStream { c in
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try payload.write(to: url)
                c.yield(.completed(url)); c.finish()
            } catch { c.finish(throwing: error) }
        }
    }
    func pause() async throws -> Data { throw BoneLocalModelDownloadError.resumeDataUnavailable }
    func cancel() async { cancelled = true }
}

private actor CancelGateOperation: BoneLocalModelDownloadOperation {
    nonisolated let stream: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>
    nonisolated let continuation: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.Continuation
    var cancelGate: CheckedContinuation<Void, Never>?
    var cancellationStarted = false
    var eventsStarted = false
    init() {
        let pair = AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    nonisolated func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        Task { await self.markStarted() }
        return stream
    }
    func markStarted() { eventsStarted = true }
    func waitForEvents() async { while !eventsStarted { await Task.yield() } }
    func waitForCancel() async { while cancelGate == nil { await Task.yield() } }
    func releaseCancel() {
        cancelGate?.resume(); cancelGate = nil
        continuation.yield(.progress(.init(downloadedBytes: 1, expectedBytes: 10)))
        continuation.finish(throwing: BoneLocalModelDownloadTransportFailure.cancelled(resumeData: nil))
    }
    func cancel() async {
        guard !cancellationStarted else { return }
        cancellationStarted = true
        await withCheckedContinuation { cancelGate = $0 }
    }
    func pause() async throws -> Data { throw BoneLocalModelDownloadError.resumeDataUnavailable }
}
private actor ReplacementTransport: BoneLocalModelDownloadTransport {
    let old: CancelGateOperation
    let payload: Data
    var destinations: [URL] = []
    init(old: CancelGateOperation, payload: Data) { self.old = old; self.payload = payload }
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        destinations.append(request.destinationURL)
        if destinations.count == 1 { return old }
        return DownloadOperationFixture(script: .success(payload), destinationURL: request.destinationURL)
    }
}
private struct SingleOperationTransport: BoneLocalModelDownloadTransport {
    let operation: any BoneLocalModelDownloadOperation
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation { operation }
}
private actor OversizeOperation: BoneLocalModelDownloadOperation {
    let external: URL
    var cancelled = false
    let emitsOversize: Bool
    init(external: URL, emitsOversize: Bool = true) { self.external = external; self.emitsOversize = emitsOversize }
    nonisolated func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        AsyncThrowingStream { c in
            if emitsOversize { c.yield(.progress(.init(downloadedBytes: .max, expectedBytes: .max))) }
            c.yield(.completed(external)); c.finish()
        }
    }
    func pause() async throws -> Data { throw BoneLocalModelDownloadError.resumeDataUnavailable }
    func cancel() async { cancelled = true }
}

private actor PauseGateOperation: BoneLocalModelDownloadOperation {
    nonisolated let stream: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>
    nonisolated let continuation: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.Continuation
    var gate: CheckedContinuation<Data, Never>?
    var started = false
    init() {
        let pair = AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.makeStream()
        stream = pair.stream; continuation = pair.continuation
    }
    nonisolated func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> {
        Task { await self.markStarted() }
        return stream
    }
    func markStarted() { started = true }
    func waitForEvents() async { while !started { await Task.yield() } }
    func waitForPause() async { while gate == nil { await Task.yield() } }
    func pause() async throws -> Data { await withCheckedContinuation { gate = $0 } }
    func releasePause() { gate?.resume(returning: Data("late".utf8)); gate = nil }
    func cancel() async {
        continuation.yield(.progress(.init(downloadedBytes: 1, expectedBytes: 21)))
        continuation.finish(throwing: BoneLocalModelDownloadTransportFailure.cancelled(resumeData: nil))
    }
}

private actor TailWriteTransport: BoneLocalModelDownloadTransport {
    let operation: PauseGateOperation
    var url: URL?
    init(operation: PauseGateOperation) { self.operation = operation }
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        url = request.destinationURL
        return operation
    }
    func destination() -> URL? { url }
}
private actor UnknownFallbackTransport: BoneLocalModelDownloadTransport {
    var count = 0
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
        count += 1
        if count == 1 { throw BoneLocalModelDownloadTransportFailure.server(statusCode: 503) }
        throw NSError(domain: "fixture", code: 1)
    }
}
