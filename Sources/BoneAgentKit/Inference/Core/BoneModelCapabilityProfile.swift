import Foundation

/// 可核验的模型级能力声明来源。
public enum BoneModelCapabilityEvidenceSource: String, Codable, Sendable {
    case official
    case runtimeSmoke
    case hostVerified
}

/// 模型级文本推理能力及其证据。`nil` Profile 表示能力未知，而不是不支持。
public struct BoneModelCapabilityProfile: Codable, Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case emptyCapabilities
        case unsupportedCapability(BoneInferenceCapability)
        case invalidVerifiedAt
        case missingVerificationIdentity
    }

    public let capabilities: Set<BoneInferenceCapability>
    public let source: BoneModelCapabilityEvidenceSource
    public let verifiedAt: String
    public let verificationIdentity: BoneCapabilityVerificationIdentity?

    public init(
        capabilities: Set<BoneInferenceCapability>,
        source: BoneModelCapabilityEvidenceSource,
        verifiedAt: String,
        verificationIdentity: BoneCapabilityVerificationIdentity? = nil
    ) throws {
        guard !capabilities.isEmpty else { throw ValidationError.emptyCapabilities }
        if let unsupported = capabilities.first(where: { $0 == .imageGeneration }) {
            throw ValidationError.unsupportedCapability(unsupported)
        }
        guard Self.isValidDate(verifiedAt) else { throw ValidationError.invalidVerifiedAt }
        if source == .runtimeSmoke,
           capabilities.contains(where: { $0 == .toolCalling || $0 == .constrainedOutput }),
           verificationIdentity == nil {
            throw ValidationError.missingVerificationIdentity
        }
        self.capabilities = capabilities
        self.source = source
        self.verifiedAt = verifiedAt
        self.verificationIdentity = verificationIdentity
    }

    /// 将模型级证据与当前 Engine/Runtime 的实际实现取交集。
    public func resolved(engineCapabilities: Set<BoneInferenceCapability>) -> Set<BoneInferenceCapability> {
        engineCapabilities.intersection(capabilities)
    }

    private enum CodingKeys: String, CodingKey {
        case capabilities
        case source
        case verifiedAt
        case verificationIdentity
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let capabilities = try container.decode(Set<BoneInferenceCapability>.self, forKey: .capabilities)
        let source = try container.decode(BoneModelCapabilityEvidenceSource.self, forKey: .source)
        let verifiedAt = try container.decode(String.self, forKey: .verifiedAt)
        let verificationIdentity = try container.decodeIfPresent(
            BoneCapabilityVerificationIdentity.self,
            forKey: .verificationIdentity
        )
        do {
            try self.init(
                capabilities: capabilities,
                source: source,
                verifiedAt: verifiedAt,
                verificationIdentity: verificationIdentity
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .capabilities,
                in: container,
                debugDescription: "Invalid model inference capability profile: \(error)"
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
