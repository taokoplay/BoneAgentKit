import Foundation

public actor BoneLocalModelDownloadCoordinator {
    // Retained by run even after cancellation removes the active token. A pending
    // pause may still perform its final write before returning, so cleanup must wait.
    private final class PauseBarrier {
        var pending = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private struct Active {
        let pauseBarrier = PauseBarrier()
        let token: UUID
        var operation: (any BoneLocalModelDownloadOperation)?
        var pausing = false
    }
    private let store: BoneLocalModelStore
    private let transport: any BoneLocalModelDownloadTransport
    private var states: [String: BoneLocalModelDownloadState] = [:]
    private var active: [String: Active] = [:]

    public init(store: BoneLocalModelStore, transport: any BoneLocalModelDownloadTransport) {
        self.store = store
        self.transport = transport
    }

    public func state(for modelID: String) -> BoneLocalModelDownloadState { states[modelID] ?? .idle }

    /// Pause succeeds only when the transport produces resume data. While it is pending,
    /// progress/completion is ignored and a second pause is rejected. Cancel wins over pause.
    public func pause(modelID: String) async throws -> Data {
        guard let current = active[modelID], !current.pausing,
              let operation = current.operation,
              case .downloading(let sourceID, _) = states[modelID] else {
            throw BoneLocalModelDownloadError.resumeDataUnavailable
        }
        active[modelID]?.pausing = true
        let barrier = current.pauseBarrier
        barrier.pending = true
        defer {
            barrier.pending = false
            for waiter in barrier.waiters { waiter.resume() }
            barrier.waiters.removeAll()
        }
        do {
            let data = try await operation.pause()
            guard active[modelID]?.token == current.token else { throw BoneLocalModelDownloadError.cancelled }
            active[modelID] = nil
            states[modelID] = .paused(sourceID: sourceID, resumeData: data)
            return data
        } catch {
            if active[modelID]?.token == current.token {
                active[modelID] = nil
                states[modelID] = .cancelled
                await operation.cancel()
            }
            throw error
        }
    }

    public func cancel(modelID: String) async {
        let operation = active.removeValue(forKey: modelID)?.operation
        states[modelID] = .cancelled
        await operation?.cancel()
    }

    private func cancel(modelID: String, token: UUID) async {
        guard active[modelID]?.token == token else { return }
        await cancel(modelID: modelID)
    }

    @discardableResult
    public func download(_ model: BoneLocalModelDescriptor, environment: BoneLocalRuntimeEnvironment,
                         policy: BoneLocalModelDownloadPolicy = .init()) async throws -> URL {
        try await execute(model, environment: environment, policy: policy,
                          sources: BoneLocalModelDownloadSecurityPolicy.orderedSources(model.artifact.sources), resumeData: nil)
    }

    @discardableResult
    public func resume(_ model: BoneLocalModelDescriptor, environment: BoneLocalRuntimeEnvironment,
                       policy: BoneLocalModelDownloadPolicy = .init()) async throws -> URL {
        guard case .paused(let sourceID, let data) = states[model.id],
              let source = model.artifact.sources.first(where: { $0.id == sourceID }) else {
            throw BoneLocalModelDownloadError.notPaused
        }
        return try await execute(model, environment: environment, policy: policy, sources: [source], resumeData: data)
    }

    private func execute(_ model: BoneLocalModelDescriptor, environment: BoneLocalRuntimeEnvironment,
                         policy: BoneLocalModelDownloadPolicy, sources: [BoneLocalModelDownloadSource],
                         resumeData: Data?) async throws -> URL {
        guard active[model.id] == nil else { throw BoneLocalModelDownloadError.alreadyActive }
        // Download plus the Store's same-volume installation copy. Reject overflow, even
        // if the caller reports Int64.max free bytes.
        let (copies, overflow1) = model.artifact.expectedByteCount.multipliedReportingOverflow(by: 2)
        let (budget, overflow2) = copies.addingReportingOverflow(policy.diskSafetyMarginBytes)
        guard model.artifact.expectedByteCount > 0, !overflow1, !overflow2,
              environment.availableDiskBytes >= budget else {
            let error = BoneLocalModelDownloadError.insufficientDiskSpace(
                required: overflow1 || overflow2 ? Int64.max : max(0, budget), available: environment.availableDiskBytes)
            // No attempt has started: retain the only resume data for a retry
            // after the Host frees space.
            if resumeData == nil { states[model.id] = .failed(error) }
            throw error
        }
        let token = UUID()
        active[model.id] = Active(token: token)
        states[model.id] = .preparing(sourceID: sources.first?.id ?? "")
        defer {
            if active[model.id]?.token == token, active[model.id]?.pausing == false { active[model.id] = nil }
        }
        return try await withTaskCancellationHandler {
            var lastError: BoneLocalModelDownloadError = .transportFailure
            for (index, source) in sources.enumerated() {
                do {
                    try check(model.id, token: token)
                    return try await run(model, source: source, resumeData: resumeData, policy: policy, token: token)
                } catch {
                    guard active[model.id]?.token == token, active[model.id]?.pausing == false else {
                        throw BoneLocalModelDownloadError.cancelled
                    }
                    if Task.isCancelled || error is CancellationError {
                        states[model.id] = .cancelled
                        throw BoneLocalModelDownloadError.cancelled
                    }
                    if let failure = error as? BoneLocalModelDownloadTransportFailure {
                        lastError = Self.map(failure)
                        if case .cancelled = failure {
                            states[model.id] = .cancelled
                            throw lastError
                        }
                        if failure.permitsSourceFallback && index + 1 < sources.count { continue }
                    } else if let failure = error as? BoneLocalModelStoreError {
                        lastError = .storeFailure(failure)
                    } else if let failure = error as? BoneLocalModelDownloadError {
                        lastError = failure
                    } else {
                        lastError = .transportFailure
                    }
                    states[model.id] = .failed(lastError)
                    throw lastError
                }
            }
            states[model.id] = .failed(lastError)
            throw lastError
        } onCancel: {
            Task { await self.cancel(modelID: model.id, token: token) }
        }
    }

    private func check(_ modelID: String, token: UUID) throws {
        guard !Task.isCancelled, active[modelID]?.token == token, active[modelID]?.pausing == false else {
            throw BoneLocalModelDownloadError.cancelled
        }
    }

    private func run(_ model: BoneLocalModelDescriptor, source: BoneLocalModelDownloadSource,
                     resumeData: Data?, policy: BoneLocalModelDownloadPolicy, token: UUID) async throws -> URL {
        try BoneLocalModelDownloadSecurityPolicy.validate(source.url, for: source)
        states[model.id] = .preparing(sourceID: source.id)
        let destinationURL = try store.downloadStagingURL()
        defer { try? FileManager.default.removeItem(at: destinationURL) }
        let request = BoneLocalModelDownloadRequest(modelID: model.id, source: source,
            destinationURL: destinationURL, expectedByteCount: model.artifact.expectedByteCount,
            resumeData: resumeData, policy: policy)
        let operation = try await transport.start(request)
        do { try check(model.id, token: token) } catch {
            await operation.cancel()
            throw error
        }
        active[model.id]?.operation = operation
        let pauseBarrier = active[model.id]!.pauseBarrier
        states[model.id] = .downloading(sourceID: source.id,
            progress: .init(downloadedBytes: 0, expectedBytes: model.artifact.expectedByteCount))
        do {
            var downloaded: Int64 = 0
            for try await event in operation.events() {
                try check(model.id, token: token)
                switch event {
                case .progress(let progress):
                    guard progress.downloadedBytes <= model.artifact.expectedByteCount else {
                        throw BoneLocalModelDownloadTransportFailure.invalidResponse(statusCode: nil)
                    }
                    downloaded = max(downloaded, progress.downloadedBytes)
                    states[model.id] = .downloading(sourceID: source.id,
                        progress: .init(downloadedBytes: downloaded, expectedBytes: model.artifact.expectedByteCount))
                case .completed(let url):
                    // The Store consumes its input on success. Never give it a path
                    // supplied by a transport outside this attempt's owned destination.
                    guard url.standardizedFileURL == destinationURL.standardizedFileURL else {
                        throw BoneLocalModelDownloadTransportFailure.invalidResponse(statusCode: nil)
                    }
                    states[model.id] = .verifying
                    let installedURL = try store.installDownloadedFile(at: url, for: model)
                    states[model.id] = .installed(installedURL)
                    return installedURL
                }
            }
            try check(model.id, token: token)
            throw BoneLocalModelDownloadTransportFailure.invalidResponse(statusCode: nil)
        } catch {
            // Do not let defer remove the destination while pause can still write
            // it. The barrier survives token removal (cancel/new-download races).
            let wasPausing = pauseBarrier.pending
            if wasPausing {
                await withCheckedContinuation { pauseBarrier.waiters.append($0) }
            } else {
                await operation.cancel()
            }
            throw error
        }
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
