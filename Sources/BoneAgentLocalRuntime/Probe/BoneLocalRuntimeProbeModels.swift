import BoneAgentKit
import Foundation

public enum BoneLocalRuntimeProbeDepth: Int, Codable, Comparable, Sendable {
    case metadata
    case load
    case smoke

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BoneLocalRuntimeAdapterDescriptor: Equatable, Sendable {
    public let id: String
    public let runtimeVersion: Int
    public let supportedFormats: Set<BoneLocalModelFormat>
    public let runtimeConstraints: BoneLocalRuntimeConstraints
    public let maximumProbeDepth: BoneLocalRuntimeProbeDepth

    public init(
        id: String,
        runtimeVersion: Int,
        supportedFormats: Set<BoneLocalModelFormat>,
        runtimeConstraints: BoneLocalRuntimeConstraints,
        maximumProbeDepth: BoneLocalRuntimeProbeDepth
    ) {
        self.id = id
        self.runtimeVersion = runtimeVersion
        self.supportedFormats = supportedFormats
        self.runtimeConstraints = runtimeConstraints
        self.maximumProbeDepth = maximumProbeDepth
    }

    public func supports(_ depth: BoneLocalRuntimeProbeDepth) -> Bool {
        depth <= maximumProbeDepth
    }
}

public enum BoneLocalRuntimeProbeCheckKind: String, Codable, Sendable {
    case installation
    case artifactIntegrity
    case formatSignature
    case adapterFormatCompatibility
    case runtimeVersion
    case deviceMemory
    case runtimePlan
    case adapterAvailability
    case modelLoad
    case smoke
}

public enum BoneLocalRuntimeProbeCheckStatus: Int, Codable, Comparable, Sendable {
    case passed
    case temporarilyUnavailable
    case unsupported
    case incompatible
    case corrupted
    case failed

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct BoneLocalRuntimeProbeCheck: Equatable, Sendable {
    public let kind: BoneLocalRuntimeProbeCheckKind
    public let status: BoneLocalRuntimeProbeCheckStatus

    public init(
        kind: BoneLocalRuntimeProbeCheckKind,
        status: BoneLocalRuntimeProbeCheckStatus
    ) {
        self.kind = kind
        self.status = status
    }
}

public enum BoneLocalRuntimeProbeStatus: Equatable, Sendable {
    case compatible
    case temporarilyUnavailable
    case unsupported
    case incompatible
    case corrupted
    case failed
}

public struct BoneLocalRuntimeProbeReport: Equatable, Sendable {
    public let modelID: String
    public let adapterID: String
    public let depth: BoneLocalRuntimeProbeDepth
    public let checks: [BoneLocalRuntimeProbeCheck]
    public let verifiedCapabilities: Set<BoneInferenceCapability>
    public let status: BoneLocalRuntimeProbeStatus

    public init(
        modelID: String,
        adapterID: String,
        depth: BoneLocalRuntimeProbeDepth,
        checks: [BoneLocalRuntimeProbeCheck],
        verifiedCapabilities: Set<BoneInferenceCapability> = []
    ) {
        self.modelID = modelID
        self.adapterID = adapterID
        self.depth = depth
        self.checks = checks
        self.verifiedCapabilities = verifiedCapabilities
        guard let mostSevere = checks.map(\.status).max() else {
            self.status = .failed
            return
        }
        switch mostSevere {
        case .passed: self.status = .compatible
        case .temporarilyUnavailable: self.status = .temporarilyUnavailable
        case .unsupported: self.status = .unsupported
        case .incompatible: self.status = .incompatible
        case .corrupted: self.status = .corrupted
        case .failed: self.status = .failed
        }
    }
}

public struct BoneLocalRuntimeAdapterProbeResult: Equatable, Sendable {
    public let check: BoneLocalRuntimeProbeCheck
    /// 本次 Probe 实际验证通过的推理能力；load/metadata Probe 通常为空。
    public let verifiedCapabilities: Set<BoneInferenceCapability>

    public init(
        check: BoneLocalRuntimeProbeCheck,
        verifiedCapabilities: Set<BoneInferenceCapability> = []
    ) {
        self.check = check
        self.verifiedCapabilities = verifiedCapabilities
    }
}

public protocol BoneLocalRuntimeAdapterProbing: Sendable {
    var descriptor: BoneLocalRuntimeAdapterDescriptor { get }

    func probe(
        model: BoneLocalModelDescriptor,
        artifactURL: URL,
        environment: BoneLocalRuntimeEnvironment,
        plan: BoneLocalRuntimePlan,
        depth: BoneLocalRuntimeProbeDepth
    ) async -> BoneLocalRuntimeAdapterProbeResult
}
