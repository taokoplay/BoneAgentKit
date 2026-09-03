import Foundation

/// 真实云 Provider Constraint Smoke 的固定失败分类；不携带请求或响应正文。
public enum BoneLiveConstraintSmokeFailure: String, Codable, CaseIterable, Sendable {
    case unsupportedCapability
    case invalidConstraint
    case invalidResponse
    case outputTruncated
    case safetyBlocked
    case authentication
    case rateLimited
    case quotaExceeded
    case network
    case other
}

/// 真实云 Provider Constraint Smoke 的脱敏聚合报告。
public struct BoneLiveConstraintSmokeReport: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public let schemaVersion: Int
    public let provider: BoneInferenceProviderKind
    public let modelID: String
    public let invocation: BoneInferenceInvocationIdentity
    public let identity: BoneProviderCapabilityVerificationIdentity
    public let attemptedCount: Int
    public let succeededCount: Int
    public let failureCounts: [BoneLiveConstraintSmokeFailure: Int]
    public let durationMilliseconds: Int
    public let verifiedAt: String

    public init(
        provider: BoneInferenceProviderKind,
        modelID: String,
        invocation: BoneInferenceInvocationIdentity,
        identity: BoneProviderCapabilityVerificationIdentity,
        attemptedCount: Int,
        succeededCount: Int,
        failureCounts: [BoneLiveConstraintSmokeFailure: Int],
        durationMilliseconds: Int,
        verifiedAt: String
    ) throws {
        guard !modelID.isEmpty,
              modelID.count <= 128,
              modelID.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value <= 0x7E }),
              provider == identity.providerKind,
              modelID == identity.modelID,
              invocation == identity.invocation,
              attemptedCount > 0,
              succeededCount >= 0,
              succeededCount <= attemptedCount,
              durationMilliseconds >= 0,
              failureCounts.values.allSatisfy({ $0 > 0 }),
              succeededCount + failureCounts.values.reduce(0, +) == attemptedCount,
              Self.isValidDate(verifiedAt) else {
            throw BoneInferenceError.invalidResponse
        }
        schemaVersion = Self.schemaVersion
        self.provider = provider
        self.modelID = modelID
        self.invocation = invocation
        self.identity = identity
        self.attemptedCount = attemptedCount
        self.succeededCount = succeededCount
        self.failureCounts = failureCounts
        self.durationMilliseconds = durationMilliseconds
        self.verifiedAt = verifiedAt
    }

    private enum CodingKeys: CodingKey {
        case schemaVersion, provider, modelID, invocation, identity
        case attemptedCount, succeededCount, failureCounts, durationMilliseconds, verifiedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .schemaVersion) == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported smoke report schema"
            )
        }
        do {
            try self.init(
                provider: container.decode(BoneInferenceProviderKind.self, forKey: .provider),
                modelID: container.decode(String.self, forKey: .modelID),
                invocation: container.decode(BoneInferenceInvocationIdentity.self, forKey: .invocation),
                identity: container.decode(BoneProviderCapabilityVerificationIdentity.self, forKey: .identity),
                attemptedCount: container.decode(Int.self, forKey: .attemptedCount),
                succeededCount: container.decode(Int.self, forKey: .succeededCount),
                failureCounts: container.decode([BoneLiveConstraintSmokeFailure: Int].self, forKey: .failureCounts),
                durationMilliseconds: container.decode(Int.self, forKey: .durationMilliseconds),
                verifiedAt: container.decode(String.self, forKey: .verifiedAt)
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .attemptedCount,
                in: container,
                debugDescription: "Invalid smoke report"
            )
        }
    }

    private static func isValidDate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return false
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil
    }
}
