import Foundation

public actor BoneLocalModelDownloadCoordinator {
    private let store: BoneLocalModelStore
    private let transport: any BoneLocalModelDownloadTransport
    private var states: [String: BoneLocalModelDownloadState] = [:]
    private var operations: [String: any BoneLocalModelDownloadOperation] = [:]

    public init(
        store: BoneLocalModelStore,
        transport: any BoneLocalModelDownloadTransport
    ) {
        self.store = store
        self.transport = transport
    }

    public func state(for modelID: String) -> BoneLocalModelDownloadState {
        states[modelID] ?? .idle
    }

    public func pause(modelID: String) async throws -> Data {
        guard let operation = operations[modelID],
              case .downloading(let sourceID, _) = states[modelID] else {
            throw BoneLocalModelDownloadError.resumeDataUnavailable
        }
        let resumeData = try await operation.pause()
        states[modelID] = .paused(sourceID: sourceID, resumeData: resumeData)
        return resumeData
    }

    @discardableResult
    public func resume(
        _ model: BoneLocalModelDescriptor,
        environment: BoneLocalRuntimeEnvironment,
        policy: BoneLocalModelDownloadPolicy = .init()
    ) async throws -> URL {
        guard case .paused(let sourceID, let resumeData) = states[model.id],
              let source = model.artifact.sources.first(where: { $0.id == sourceID }) else {
            throw BoneLocalModelDownloadError.notPaused
        }
        guard operations[model.id] == nil else {
            throw BoneLocalModelDownloadError.alreadyActive
        }
        let required = model.artifact.expectedByteCount + policy.diskSafetyMarginBytes
        guard environment.availableDiskBytes >= required else {
            throw BoneLocalModelDownloadError.insufficientDiskSpace(
                required: required,
                available: environment.availableDiskBytes
            )
        }
        do {
            return try await run(
                model,
                source: source,
                resumeData: resumeData,
                policy: policy
            )
        } catch let error as BoneLocalModelStoreError {
            let mapped = BoneLocalModelDownloadError.storeFailure(error)
            states[model.id] = .failed(mapped)
            throw mapped
        } catch let failure as BoneLocalModelDownloadTransportFailure {
            let mapped = Self.map(failure)
            states[model.id] = .failed(mapped)
            throw mapped
        }
    }

    public func cancel(modelID: String) async {
        if let operation = operations[modelID] {
            await operation.cancel()
        }
        operations[modelID] = nil
        states[modelID] = .cancelled
    }

    @discardableResult
    public func download(
        _ model: BoneLocalModelDescriptor,
        environment: BoneLocalRuntimeEnvironment,
        policy: BoneLocalModelDownloadPolicy = .init()
    ) async throws -> URL {
        guard operations[model.id] == nil else {
            throw BoneLocalModelDownloadError.alreadyActive
        }
        let required = model.artifact.expectedByteCount + policy.diskSafetyMarginBytes
        guard environment.availableDiskBytes >= required else {
            let error = BoneLocalModelDownloadError.insufficientDiskSpace(
                required: required,
                available: environment.availableDiskBytes
            )
            states[model.id] = .failed(error)
            throw error
        }

        let sources = BoneLocalModelDownloadSecurityPolicy.orderedSources(model.artifact.sources)
        var lastError: BoneLocalModelDownloadError = .transportFailure
        for (index, source) in sources.enumerated() {
            do {
                return try await run(
                    model,
                    source: source,
                    resumeData: nil,
                    policy: policy
                )
            } catch let failure as BoneLocalModelDownloadTransportFailure {
                lastError = Self.map(failure)
                if case .cancelled(let resumeData) = failure {
                    if case .paused = states[model.id] { throw lastError }
                    if let resumeData {
                        states[model.id] = .paused(sourceID: source.id, resumeData: resumeData)
                    } else {
                        states[model.id] = .cancelled
                    }
                    throw lastError
                }
                let hasFallback = index + 1 < sources.count
                if failure.permitsSourceFallback && hasFallback { continue }
                states[model.id] = .failed(lastError)
                throw lastError
            } catch let error as BoneLocalModelStoreError {
                lastError = .storeFailure(error)
                states[model.id] = .failed(lastError)
                throw lastError
            } catch let error as BoneLocalModelDownloadError {
                lastError = error
                states[model.id] = .failed(error)
                throw error
            } catch {
                states[model.id] = .failed(lastError)
                throw lastError
            }
        }
        states[model.id] = .failed(lastError)
        throw lastError
    }

    private func run(
        _ model: BoneLocalModelDescriptor,
        source: BoneLocalModelDownloadSource,
        resumeData: Data?,
        policy: BoneLocalModelDownloadPolicy
    ) async throws -> URL {
        try BoneLocalModelDownloadSecurityPolicy.validate(source.url, for: source)
        states[model.id] = .preparing(sourceID: source.id)
        let partialURL = try store.partialURL(for: model)
        let destinationURL = partialURL.appendingPathExtension("download")
        let request = BoneLocalModelDownloadRequest(
            modelID: model.id,
            source: source,
            destinationURL: destinationURL,
            expectedByteCount: model.artifact.expectedByteCount,
            resumeData: resumeData,
            policy: policy
        )
        let operation = try await transport.start(request)
        operations[model.id] = operation
        states[model.id] = .downloading(
            sourceID: source.id,
            progress: .init(downloadedBytes: 0, expectedBytes: model.artifact.expectedByteCount)
        )
        defer { operations[model.id] = nil }

        for try await event in operation.events() {
            switch event {
            case .progress(let progress):
                states[model.id] = .downloading(sourceID: source.id, progress: progress)
            case .completed(let url):
                states[model.id] = .verifying
                let installedURL = try store.installDownloadedFile(at: url, for: model)
                states[model.id] = .installed(installedURL)
                return installedURL
            }
        }
        throw BoneLocalModelDownloadTransportFailure.invalidResponse(statusCode: nil)
    }

    private static func map(
        _ failure: BoneLocalModelDownloadTransportFailure
    ) -> BoneLocalModelDownloadError {
        switch failure {
        case .networkUnavailable: return .networkUnavailable
        case .timedOut: return .timedOut
        case .server(let statusCode): return .serverFailure(statusCode: statusCode)
        case .client(let statusCode): return .invalidResponse(statusCode: statusCode)
        case .untrustedRedirect: return .untrustedURL
        case .invalidResponse(let statusCode): return .invalidResponse(statusCode: statusCode)
        case .cancelled: return .cancelled
        case .other: return .transportFailure
        }
    }
}
