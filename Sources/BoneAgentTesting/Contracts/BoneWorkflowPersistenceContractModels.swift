import BoneAgentKit

public enum BoneWorkflowPersistenceContractCase: String, CaseIterable, Codable, Sendable {
    case createLoad
    case rejectedBundleAtomicity
    case concurrentCAS
    case generationFencing
    case reopenedRead
    case independentConnectionConsistency
    /// Required: valid checkpoint JSON is schema-opaque and preserved byte-for-byte.
    case opaqueCheckpointPayload
    /// Required: create preserves any UInt64 generation; acquisition is a separate CAS.
    case creationLeaseGeneration
}

public enum BoneWorkflowPersistenceContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed
    case operationFailed
    /// A valid seed was rejected during create; this does not diagnose the adapter's cause.
    case seedCreateRejected
    /// The initial load threw before the scenario's target behavior could be checked.
    case seedLoadFailed
    /// A valid JSON create/commit threw in the dedicated opaque-payload probe.
    case opaquePayloadRejected
    /// A create threw in the dedicated initial-generation probe.
    case creationGenerationRejected
    case snapshotMismatch
    case invalidBundleAccepted
    case unexpectedRejection
    case rejectedWriteChangedSnapshot
    case casWinnerCount
    case generationNotAdvanced
    case staleWorkerAccepted
    case cleanupFailed
}

public enum BoneWorkflowPersistenceContractCapability: String, Codable, Sendable {
    case reopenAfterClosingPrimary
    case independentConnection
}

/// All report fields are fixed allowlists: no adapter errors, payloads, paths or identifiers.
public enum BoneWorkflowPersistenceContractOutcome: Equatable, Codable, Sendable {
    case passed
    case skipped(BoneWorkflowPersistenceContractCapability)
    case failed([BoneWorkflowPersistenceContractFailure])
}

public struct BoneWorkflowPersistenceContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowPersistenceContractCase
    public let outcome: BoneWorkflowPersistenceContractOutcome

    public init(scenario: BoneWorkflowPersistenceContractCase, outcome: BoneWorkflowPersistenceContractOutcome) {
        self.scenario = scenario
        self.outcome = outcome
    }
}

/// One isolated namespace per factory invocation. Cleanup owns all resources, including
/// reopened/secondary connections, and must tolerate partially failed operations.
/// A factory that throws before returning retains responsibility for its own cleanup.
public struct BoneWorkflowPersistenceContractFixture: Sendable {
    public let persistence: any BoneWorkflowPersistence
    /// Host declaration: close/release the original connection and return a newly opened
    /// instance of the same backing store. Returning the same actor does NOT meet this
    /// capability. This is an API-level reopen probe, not proof of physical disk durability.
    public let reopenAfterClosingPrimary: (@Sendable () async throws -> any BoneWorkflowPersistence)?
    /// Host declaration: a second independent connection to the same backing store,
    /// concurrently usable with the primary. A wrapper around the same actor is insufficient.
    public let openIndependentConnection: (@Sendable () async throws -> any BoneWorkflowPersistence)?
    public let cleanup: @Sendable () async throws -> Void

    public init(
        persistence: any BoneWorkflowPersistence,
        reopenAfterClosingPrimary: (@Sendable () async throws -> any BoneWorkflowPersistence)? = nil,
        openIndependentConnection: (@Sendable () async throws -> any BoneWorkflowPersistence)? = nil,
        cleanup: @escaping @Sendable () async throws -> Void
    ) {
        self.persistence = persistence
        self.reopenAfterClosingPrimary = reopenAfterClosingPrimary
        self.openIndependentConnection = openIndependentConnection
        self.cleanup = cleanup
    }
}

public typealias BoneWorkflowPersistenceContractFixtureFactory = @Sendable (
    BoneWorkflowPersistenceContractCase
) async throws -> BoneWorkflowPersistenceContractFixture
