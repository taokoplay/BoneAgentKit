import Foundation

public enum BoneLlamaRuntimePhase: String, Codable, Equatable, Sendable {
    case notLoaded
    case loading
    case loaded
    case generating
    case cancelling
    case unloading
    case failed
}

public struct BoneLlamaRuntimeState: Equatable, Sendable {
    public let phase: BoneLlamaRuntimePhase
    public let revision: UInt64
    public let runtimeVersion: Int
    public let configuration: BoneLlamaRuntimeConfiguration?
    public let failure: BoneLlamaRuntimeError?

    public init(
        phase: BoneLlamaRuntimePhase,
        revision: UInt64,
        runtimeVersion: Int,
        configuration: BoneLlamaRuntimeConfiguration? = nil,
        failure: BoneLlamaRuntimeError? = nil
    ) {
        self.phase = phase
        self.revision = revision
        self.runtimeVersion = runtimeVersion
        self.configuration = configuration
        self.failure = failure
    }
}

public struct BoneLlamaModelState: Equatable, Sendable {
    public let modelID: String
    public let phase: BoneLlamaRuntimePhase
    public let revision: UInt64
    public let runtimeVersion: Int
    public let configuration: BoneLlamaRuntimeConfiguration?
    public let failure: BoneLlamaRuntimeError?

    public init(modelID: String, runtimeState: BoneLlamaRuntimeState) {
        self.modelID = modelID
        phase = runtimeState.phase
        revision = runtimeState.revision
        runtimeVersion = runtimeState.runtimeVersion
        configuration = runtimeState.configuration
        failure = runtimeState.failure
    }
}

public protocol BoneLlamaRuntimeStateObserving: BoneLlamaRuntime {
    func currentRuntimeState() async -> BoneLlamaRuntimeState
    func runtimeStateUpdates() async -> AsyncStream<BoneLlamaRuntimeState>
}
