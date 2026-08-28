import Foundation

public enum BoneEffectRecoveryStrategy: String, Codable, Equatable, Sendable {
    case naturallyIdempotent
    case idempotencyKeyRequired
    case reconcilable
    case compensatable
    case nonRecoverableRequiresUserDecision
}

public enum BoneEffectPhase: String, Codable, Equatable, Sendable {
    case intentPersisted
    case executionStarted
}

public enum BoneEffectError: Error, Codable, Equatable, Sendable {
    case missingIdempotencyKey
    case invalidDigest
    case invalidIdentity
}

public struct BoneEffectIntent: Codable, Equatable, Sendable {
    public let id: BoneEffectID
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let toolCallID: BoneToolCallID
    public let recoveryStrategy: BoneEffectRecoveryStrategy
    public let idempotencyKey: String?
    /// 持久化恢复时使用的不可逆身份摘要；不能作为外部请求的原始幂等键。
    public let idempotencyKeyDigest: String?
    public let argumentsDigest: String
    public let phase: BoneEffectPhase
    public let leaseGeneration: UInt64

    public init(
        id: BoneEffectID,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        toolCallID: BoneToolCallID,
        recoveryStrategy: BoneEffectRecoveryStrategy,
        idempotencyKey: String?,
        idempotencyKeyDigest: String? = nil,
        argumentsDigest: String,
        phase: BoneEffectPhase,
        leaseGeneration: UInt64
    ) throws {
        if recoveryStrategy == .idempotencyKeyRequired,
           idempotencyKey?.isEmpty != false,
           idempotencyKeyDigest?.isEmpty != false {
            throw BoneEffectError.missingIdempotencyKey
        }
        if let idempotencyKey,
           idempotencyKey.isEmpty || idempotencyKey.count > 256 {
            throw BoneEffectError.invalidIdentity
        }
        if let idempotencyKeyDigest,
           idempotencyKeyDigest.count != 64 ||
           !idempotencyKeyDigest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) {
            throw BoneEffectError.invalidDigest
        }
        guard argumentsDigest.count == 64,
              argumentsDigest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw BoneEffectError.invalidDigest
        }
        self.id = id
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.toolCallID = toolCallID
        self.recoveryStrategy = recoveryStrategy
        self.idempotencyKey = idempotencyKey
        self.idempotencyKeyDigest = idempotencyKeyDigest
        self.argumentsDigest = argumentsDigest
        self.phase = phase
        self.leaseGeneration = leaseGeneration
    }
}
