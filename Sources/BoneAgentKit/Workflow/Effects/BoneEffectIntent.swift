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
    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID
        case runID
        case stepID
        case attemptID
        case toolCallID
        case recoveryStrategy
        case idempotencyKey
        case idempotencyKeyDigest
        case argumentsDigest
        case phase
        case leaseGeneration
    }
    public let id: BoneEffectID
    /// 可选的 Agent Session 身份，用于把新建 Effect 绑定到长期会话。
    public let sessionID: String?
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
        sessionID: String? = nil,
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
        if let sessionID,
           sessionID.isEmpty || sessionID.count > 128 {
            throw BoneEffectError.invalidIdentity
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
        self.sessionID = sessionID
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

    /// 从持久化 Effect Intent 解码，并兼容新增 sessionID 之前的历史记录。
    /// - Parameter decoder: 包含 Effect Intent 字段的持久化解码器。
    /// - Throws: 历史字段缺失、身份不合法或摘要校验失败时抛出错误。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(BoneEffectID.self, forKey: .id),
            sessionID: container.decodeIfPresent(String.self, forKey: .sessionID),
            runID: container.decode(BoneRunID.self, forKey: .runID),
            stepID: container.decode(BoneStepID.self, forKey: .stepID),
            attemptID: container.decode(BoneAttemptID.self, forKey: .attemptID),
            toolCallID: container.decode(BoneToolCallID.self, forKey: .toolCallID),
            recoveryStrategy: container.decode(BoneEffectRecoveryStrategy.self, forKey: .recoveryStrategy),
            idempotencyKey: container.decodeIfPresent(String.self, forKey: .idempotencyKey),
            idempotencyKeyDigest: container.decodeIfPresent(String.self, forKey: .idempotencyKeyDigest),
            argumentsDigest: container.decode(String.self, forKey: .argumentsDigest),
            phase: container.decode(BoneEffectPhase.self, forKey: .phase),
            leaseGeneration: container.decode(UInt64.self, forKey: .leaseGeneration)
        )
    }
}
