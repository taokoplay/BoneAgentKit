import Foundation

public enum BoneEffectOutcome: String, Codable, Equatable, Sendable {
    case succeeded
    case failed
    case reconciledSucceeded
    case reconciledFailed
    case compensated
}

public struct BoneEffectReceipt: Codable, Equatable, Sendable {
    public let effectID: BoneEffectID
    public let outcome: BoneEffectOutcome
    public let resultDigest: String
    public let leaseGeneration: UInt64

    public init(
        effectID: BoneEffectID,
        outcome: BoneEffectOutcome,
        resultDigest: String,
        leaseGeneration: UInt64
    ) throws {
        guard resultDigest.count == 64,
              resultDigest.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw BoneEffectError.invalidDigest
        }
        self.effectID = effectID
        self.outcome = outcome
        self.resultDigest = resultDigest
        self.leaseGeneration = leaseGeneration
    }
}
