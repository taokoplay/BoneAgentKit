import Foundation

/// 构造当前云 Provider 执行身份；只将 Endpoint 规范化结果散列后写入身份。
enum BoneProviderVerificationIdentitySupport {
    static func identity(
        configuration: BoneInferenceProviderConfiguration,
        protocolVariant: BoneInferenceProtocolVariant,
        apiVersion: String,
        modelID: String,
        requestMapperID: String,
        requestMapperVersion: String,
        responseDecoderID: String,
        responseDecoderVersion: String,
        constraintDialectID: String,
        constraintDialectVersion: String,
        invocation: BoneInferenceInvocation
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        let endpointMaterial = [
            configuration.kind.rawValue,
            configuration.baseURL.absoluteString,
            configuration.endpointOverrides["chat"] ?? "",
            configuration.usesFullEndpointURL ? "full" : "relative",
        ].joined(separator: "|")
        return try .init(
            providerKind: configuration.kind,
            protocolVariant: protocolVariant,
            endpointIdentityDigest: BoneSHA256.hexDigest(Data(endpointMaterial.utf8)),
            apiVersion: apiVersion,
            modelID: modelID,
            requestMapperID: requestMapperID,
            requestMapperVersion: requestMapperVersion,
            responseDecoderID: responseDecoderID,
            responseDecoderVersion: responseDecoderVersion,
            constraintDialectID: constraintDialectID,
            constraintDialectVersion: constraintDialectVersion,
            invocation: invocation == .streaming ? .streaming : .nonStreaming
        )
    }

    static func isVerified(
        profile: BoneModelCapabilityProfile?,
        currentIdentity: BoneProviderCapabilityVerificationIdentity
    ) -> Bool {
        guard let profile,
              profile.capabilities.contains(.constrainedOutput),
              profile.source == .providerSmoke else {
            return false
        }
        return profile.providerVerificationIdentities.contains(currentIdentity)
    }
}
