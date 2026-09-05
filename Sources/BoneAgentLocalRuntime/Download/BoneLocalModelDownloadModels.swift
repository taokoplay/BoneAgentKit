import Foundation

public struct BoneLocalModelDownloadPolicy: Equatable, Sendable {
    public let diskSafetyMarginBytes: Int64
    public let allowsCellularAccess: Bool
    public let requestTimeoutSeconds: TimeInterval
    public let resourceTimeoutSeconds: TimeInterval

    public init(
        diskSafetyMarginBytes: Int64 = 536_870_912,
        allowsCellularAccess: Bool = false,
        requestTimeoutSeconds: TimeInterval = 45,
        resourceTimeoutSeconds: TimeInterval = 3_600
    ) {
        self.diskSafetyMarginBytes = max(0, diskSafetyMarginBytes)
        self.allowsCellularAccess = allowsCellularAccess
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.resourceTimeoutSeconds = max(1, resourceTimeoutSeconds)
    }
}

public struct BoneLocalModelDownloadProgress: Equatable, Sendable {
    public let downloadedBytes: Int64
    public let expectedBytes: Int64

    public var fractionCompleted: Double {
        guard expectedBytes > 0 else { return 0 }
        return min(1, max(0, Double(downloadedBytes) / Double(expectedBytes)))
    }

    public init(downloadedBytes: Int64, expectedBytes: Int64) {
        self.downloadedBytes = max(0, downloadedBytes)
        self.expectedBytes = expectedBytes
    }
}

public enum BoneLocalModelDownloadError: Error, Equatable, Sendable {
    case alreadyActive
    case insufficientDiskSpace(required: Int64, available: Int64)
    case untrustedURL
    case invalidResponse(statusCode: Int?)
    case networkUnavailable
    case timedOut
    case serverFailure(statusCode: Int)
    case resumeDataUnavailable
    case notPaused
    case cancelled
    case transportFailure
    case storeFailure(BoneLocalModelStoreError)
}

public enum BoneLocalModelDownloadState: Equatable, Sendable {
    case idle
    case preparing(sourceID: String)
    case downloading(sourceID: String, progress: BoneLocalModelDownloadProgress)
    case paused(sourceID: String, resumeData: Data)
    case verifying
    case installed(URL)
    case cancelled
    case failed(BoneLocalModelDownloadError)
}

public struct BoneLocalModelDownloadRequest: Sendable {
    public let modelID: String
    public let source: BoneLocalModelDownloadSource
    public let destinationURL: URL
    public let expectedByteCount: Int64
    public let resumeData: Data?
    public let policy: BoneLocalModelDownloadPolicy

    public init(
        modelID: String,
        source: BoneLocalModelDownloadSource,
        destinationURL: URL,
        expectedByteCount: Int64,
        resumeData: Data? = nil,
        policy: BoneLocalModelDownloadPolicy
    ) {
        self.modelID = modelID
        self.source = source
        self.destinationURL = destinationURL
        self.expectedByteCount = expectedByteCount
        self.resumeData = resumeData
        self.policy = policy
    }
}

public enum BoneLocalModelDownloadTransportEvent: Sendable {
    case progress(BoneLocalModelDownloadProgress)
    case completed(URL)
}

public enum BoneLocalModelDownloadTransportFailure: Error, Equatable, Sendable {
    case networkUnavailable
    case timedOut
    case server(statusCode: Int)
    case client(statusCode: Int)
    case untrustedRedirect
    case invalidResponse(statusCode: Int?)
    case cancelled(resumeData: Data?)
    case other

    public var permitsSourceFallback: Bool {
        switch self {
        case .networkUnavailable, .timedOut, .server:
            return true
        case .client, .untrustedRedirect, .invalidResponse, .cancelled, .other:
            return false
        }
    }
}

public protocol BoneLocalModelDownloadOperation: Sendable {
    func events() -> AsyncThrowingStream<BoneLocalModelDownloadTransportEvent, Error>
    /// Stop publishing events/files before returning resume data. Failure to obtain
    /// resume data is not a successful pause; the coordinator cancels the operation.
    func pause() async throws -> Data
    /// Idempotently stop the operation. After returning, no destination-file writes
    /// may occur. Custom transports must honor this for safe owned-file cleanup.
    func cancel() async
}

public protocol BoneLocalModelDownloadTransport: Sendable {
    /// Publish completed files only at request.destinationURL. If start throws, it
    /// must leave no asynchronous writer using that destination. A late successful
    /// start may immediately be cancelled without events() ever being requested.
    func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation
}
