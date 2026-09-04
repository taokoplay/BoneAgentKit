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
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        let safeHeaders: [(name: String, value: String)] = configuration.customHeaders.compactMap {
            guard !Self.isSensitiveHeader($0.key) else { return nil }
            return ($0.key.lowercased(), $0.value)
        }
        let sortedHeaders = safeHeaders.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        let semanticHeaders = sortedHeaders.map {
            "\($0.name):\($0.value)"
        }.joined(separator: "\u{1F}")
        let endpointMaterial = [
            configuration.kind.rawValue,
            configuration.baseURL.absoluteString,
            configuration.endpointOverrides["chat"] ?? "",
            configuration.usesFullEndpointURL ? "full" : "relative",
            configuration.authenticationMode.rawValue,
            semanticHeaders,
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

    private static func isSensitiveHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "authorization", "proxy-authorization", "cookie", "set-cookie",
             "x-api-key", "api-key", "x-goog-api-key":
            return true
        default:
            return false
        }
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
