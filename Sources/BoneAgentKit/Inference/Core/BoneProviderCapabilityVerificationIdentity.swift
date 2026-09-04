import Foundation

/// 绑定云模型能力证据的完整 Provider 执行组合。
///
/// 仅保存稳定 ID、版本和 Endpoint 身份摘要；不得保存凭据、Header、Prompt、Schema、输出或完整 URL。
public struct BoneProviderCapabilityVerificationIdentity: Codable, Equatable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case invalidIdentity
    }

    public let providerKind: BoneInferenceProviderKind
    public let protocolVariant: BoneInferenceProtocolVariant
    public let endpointIdentityDigest: String
    public let apiVersion: String
    public let modelID: String
    public let requestMapperID: String
    public let requestMapperVersion: String
    public let responseDecoderID: String
    public let responseDecoderVersion: String
    public let constraintDialectID: String
    public let constraintDialectVersion: String
    public let invocation: BoneInferenceInvocationMode

    public init(
        providerKind: BoneInferenceProviderKind,
        protocolVariant: BoneInferenceProtocolVariant,
        endpointIdentityDigest: String,
        apiVersion: String,
        modelID: String,
        requestMapperID: String,
        requestMapperVersion: String,
        responseDecoderID: String,
        responseDecoderVersion: String,
        constraintDialectID: String,
        constraintDialectVersion: String,
        invocation: BoneInferenceInvocationMode
    ) throws {
        let components = [
            apiVersion, modelID, requestMapperID, requestMapperVersion,
            responseDecoderID, responseDecoderVersion,
            constraintDialectID, constraintDialectVersion,
        ]
        guard Self.isSHA256(endpointIdentityDigest),
              components.allSatisfy(Self.isValidComponent) else {
            throw ValidationError.invalidIdentity
        }
        self.providerKind = providerKind
        self.protocolVariant = protocolVariant
        self.endpointIdentityDigest = endpointIdentityDigest.lowercased()
        self.apiVersion = apiVersion
        self.modelID = modelID
        self.requestMapperID = requestMapperID
        self.requestMapperVersion = requestMapperVersion
        self.responseDecoderID = responseDecoderID
        self.responseDecoderVersion = responseDecoderVersion
        self.constraintDialectID = constraintDialectID
        self.constraintDialectVersion = constraintDialectVersion
        self.invocation = invocation
    }

    public func matches(_ current: Self) -> Bool { self == current }

    private static func isSHA256(_ value: String) -> Bool {
        value.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 128 && value.unicodeScalars.allSatisfy {
            $0.value >= 0x21 && $0.value <= 0x7E
        }
    }
}
