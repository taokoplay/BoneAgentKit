import CryptoKit
import Foundation
import Testing
import BoneAgentKit
import BoneAgentLocalModels
@testable import WorkflowRunnerDemo

/// Every transport below is an in-process fixture. No URLSession, external
/// endpoint, real model, or network request is used by these tests.
struct LocalModelServiceTests: Sendable {
    @Test
    func catalogImportRestoreAndSnapshotsNeverStartTransport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineFixtureTransport()
        let service = try makeService(root, transport: transport)
        #expect(try await service.snapshot().entries.isEmpty)
        try await service.importCatalog(data: manifest())
        let snapshot = try await service.snapshot()
        #expect(snapshot.catalogVersion == 1)
        #expect(snapshot.entries.count == 1)
        #expect(snapshot.entries.first?.installation == .notInstalled)
        #expect(await transport.startCount == 0)

        let restored = try makeService(root, transport: transport)
        #expect(try await restored.snapshot().entries.first?.model.id == "offline-fixture")
        #expect(await transport.startCount == 0)
        do {
            try await restored.importCatalog(data: Data(count: DemoLocalModelService.maximumCatalogBytes + 1))
            Issue.record("Oversized manifest accepted")
        } catch { #expect(error as? DemoLocalModelServiceError == .catalogTooLarge) }
        #expect(try await restored.snapshot().entries.count == 1)
        try Data("broken saved catalog".utf8).write(to: root.appendingPathComponent("catalog.json"))
        let recoverable = try makeService(root, transport: transport)
        #expect(try await recoverable.snapshot().catalogIssue != nil)
        try await recoverable.importCatalog(data: manifest())
        #expect(try await recoverable.snapshot().catalogIssue == nil)
        #expect(await transport.startCount == 0)
    }

    @Test
    func offlineBytesUseSDKInstallationProbeAndScopedDeletion() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineFixtureTransport()
        let service = try makeService(root, transport: transport)
        try await service.importCatalog(data: manifest())
        try await service.download(modelID: "offline-fixture", allowsCellularAccess: false)
        let snapshot = try await service.snapshot()
        let entry = try #require(snapshot.entries.first)
        #expect(entry.isInstalled)
        #expect(entry.storedByteCount == Int64(Self.bytes.count))
        #expect(await transport.startCount == 1)
        #expect(await transport.lastAllowsCellular == false)
        let probe = try await service.inspect(modelID: entry.id)
        #expect(probe.report.status == .unsupported)
        #expect(probe.report.checks.contains(.init(kind: .artifactIntegrity, status: .passed)))
        #expect(probe.report.checks.contains(.init(kind: .formatSignature, status: .passed)))
        #expect(probe.report.checks.contains(.init(kind: .adapterAvailability, status: .unsupported)))
        #expect(probe.report.verifiedCapabilities.isEmpty)
        #expect(probe.report.verificationIdentity == nil)

        do {
            try await service.importCatalog(data: manifest(models: []))
            Issue.record("An installed asset lost its catalog descriptor")
        } catch { #expect(error as? DemoLocalModelServiceError == .installedCatalogConflict) }
        guard case .installed(let installedURL) = entry.installation else { return }
        // Size-only refresh must not claim SHA verification of same-size tampering.
        try Data(repeating: 0, count: Self.bytes.count).write(to: installedURL)
        #expect(try await service.snapshot().entries.first?.isInstalled == true)
        let corruptProbe = try await service.inspect(modelID: entry.id)
        #expect(corruptProbe.report.status == .corrupted)
        #expect(corruptProbe.report.checks.contains(.init(kind: .artifactIntegrity, status: .corrupted)))

        let unrelated = root.appendingPathComponent("unrelated.txt")
        try Data("keep".utf8).write(to: unrelated)
        do {
            try await service.delete(modelID: "../unrelated.txt")
            Issue.record("Unknown asset was eligible for deletion")
        } catch { #expect(error as? DemoLocalModelServiceError == .unknownModel) }
        try await service.delete(modelID: entry.id)
        let deleted = try await service.snapshot()
        #expect(deleted.entries.first?.installation == .notInstalled)
        #expect(deleted.entries.first?.hasStoredAsset == false)
        #expect(try Data(contentsOf: unrelated) == Data("keep".utf8))
        // SDK coordinator history can remain installed; Store is authoritative.
        if case .installed = deleted.entries.first?.download {} else { Issue.record("Expected SDK transfer history") }
        try await service.importCatalog(data: manifest(models: []))
        #expect(try await service.snapshot().entries.isEmpty)
    }

    @Test
    func sdkDiskPreflightRejectsBeforeStartingOfflineTransport() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineFixtureTransport()
        let service = try makeService(root, transport: transport, availableDisk: 0)
        try await service.importCatalog(data: manifest())
        do {
            try await service.download(modelID: "offline-fixture", allowsCellularAccess: false)
            Issue.record("Insufficient disk space was accepted")
        } catch {
            guard case .insufficientDiskSpace(let required, let available) = error as? BoneLocalModelDownloadError else {
                Issue.record("Unexpected error: \(error)"); return
            }
            #expect(required == Int64(Self.bytes.count) * 2 + BoneLocalModelDownloadPolicy().diskSafetyMarginBytes)
            #expect(available == 0)
        }
        #expect(await transport.startCount == 0)
        #expect(try await service.snapshot().entries.first?.hasStoredAsset == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDrainsOfflineOperationAndBlocksConcurrentMutation() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineFixtureTransport(holdsCompletion: true)
        let service = try makeService(root, transport: transport)
        try await service.importCatalog(data: manifest())
        let task = Task { try await service.download(modelID: "offline-fixture", allowsCellularAccess: false) }
        await transport.waitForStart()
        do {
            try await service.importCatalog(data: manifest(models: []))
            Issue.record("Catalog mutated during an active transfer")
        } catch { #expect(error as? DemoLocalModelServiceError == .busy) }
        do {
            try await service.delete(modelID: "offline-fixture")
            Issue.record("Asset mutated during an active transfer")
        } catch { #expect(error as? DemoLocalModelServiceError == .busy) }
        task.cancel()
        await service.cancelDownload(modelID: "offline-fixture")
        do { try await task.value; Issue.record("Cancelled operation succeeded") }
        catch { #expect(error as? BoneLocalModelDownloadError == .cancelled || error is CancellationError) }
        let snapshot = try await service.snapshot()
        #expect(snapshot.entries.first?.download == .cancelled)
        #expect(snapshot.entries.first?.installation == .notInstalled)
        #expect(snapshot.entries.first?.hasStoredAsset == false)
    }

    @Test
    func offlineUIModeRejectsEvenExplicitRequests() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = OfflineFixtureTransport()
        let service = try makeService(root, transport: transport, networkEnabled: false)
        try await service.importCatalog(data: manifest())
        do {
            try await service.download(modelID: "offline-fixture", allowsCellularAccess: true)
            Issue.record("Offline UI mode started transport")
        } catch { #expect(error as? DemoLocalModelServiceError == .networkDisabled) }
        #expect(await transport.startCount == 0)
        #expect(try await service.snapshot().networkEnabled == false)
    }

    private static let bytes = Data("GGUFoffline fixture only".utf8)

    private func makeService(
        _ root: URL, transport: OfflineFixtureTransport,
        availableDisk: Int64 = 2_147_483_648, networkEnabled: Bool = true
    ) throws -> DemoLocalModelService {
        try DemoLocalModelService(rootURL: root, transport: transport, environmentProvider: { _ in
            .init(physicalMemoryBytes: 8_589_934_592, availableDiskBytes: availableDisk,
                  activeProcessorCount: 4, isSimulator: true, isLowPowerModeEnabled: false, thermalState: .nominal)
        }, networkEnabled: networkEnabled)
    }

    private func temporaryRoot() -> URL {
        let parent = ProcessInfo.processInfo.environment["PI_SCRATCH_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        return parent.appendingPathComponent("AgentLabLocalModelTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func manifest(models: [BoneLocalModelDescriptor]? = nil) throws -> Data {
        struct Manifest: Encodable {
            let schemaVersion = 1
            let catalogVersion = 1
            let runtimeVersion = 1
            let models: [BoneLocalModelDescriptor]
        }
        let fixtureURL = try #require(URL(string: "https://offline-fixture.invalid/model"))
        let descriptor = BoneLocalModelDescriptor(
            id: "offline-fixture", displayName: "Offline fixture (not a model)", family: "fixture", format: .gguf,
            parameterCount: 1, quantization: "fixture", minimumMemoryBytes: 1, recommendedContextTokens: 512,
            minimumRuntimeVersion: 1,
            contextLimits: try .init(contextWindowTokens: 512, maximumInputTokens: nil, maximumOutputTokens: 32,
                                     source: .official, verifiedAt: "fixture", documentationURL: fixtureURL),
            artifact: .init(fileName: "fixture.gguf", expectedByteCount: Int64(Self.bytes.count),
                            sha256: SHA256.hash(data: Self.bytes).map { String(format: "%02x", $0) }.joined(),
                            sources: [.init(id: "offline", url: fixtureURL, allowedHosts: ["offline-fixture.invalid"], priority: 0)]),
            license: .init(name: "fixture", url: fixtureURL, modelCardURL: fixtureURL)
        )
        return try JSONEncoder().encode(Manifest(models: models ?? [descriptor]))
    }

    private actor OfflineFixtureTransport: BoneLocalModelDownloadTransport {
        let holdsCompletion: Bool
        private(set) var startCount = 0
        private(set) var lastAllowsCellular: Bool?
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(holdsCompletion: Bool = false) { self.holdsCompletion = holdsCompletion }

        func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
            startCount += 1
            lastAllowsCellular = request.policy.allowsCellularAccess
            let pair = AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.makeStream()
            if !holdsCompletion {
                try LocalModelServiceTests.bytes.write(to: request.destinationURL)
                pair.continuation.yield(.progress(.init(downloadedBytes: Int64(LocalModelServiceTests.bytes.count), expectedBytes: request.expectedByteCount)))
                pair.continuation.yield(.completed(request.destinationURL))
                pair.continuation.finish()
            }
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
            return Operation(stream: pair.stream, continuation: pair.continuation)
        }

        func waitForStart() async {
            if startCount > 0 { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    private struct Operation: BoneLocalModelDownloadOperation {
        let stream: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>
        let continuation: AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>.Continuation
        func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error> { stream }
        func pause() async throws -> Data { throw BoneLocalModelDownloadError.resumeDataUnavailable }
        func cancel() async { continuation.finish(throwing: BoneLocalModelDownloadTransportFailure.cancelled(resumeData: nil)) }
    }
}
