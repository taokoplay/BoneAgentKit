import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 统一构造 Provider JSON 请求；不负责供应商业务正文映射。
public enum BoneInferenceProviderRequestBuilder {
    public static func makeJSONRequest(
        configuration: BoneInferenceProviderConfiguration,
        operation: String,
        defaultPath: String,
        method: String = "POST",
        usesFullEndpointURL: Bool = false,
        fixedHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        guard !configuration.apiKey.isEmpty else {
            throw BoneInferenceTransportError.invalidCredential
        }
        let endpoint = configuration.endpointOverrides[operation] ?? defaultPath
        let url: URL
        if usesFullEndpointURL && configuration.usesFullEndpointURL {
            url = try BoneInferenceEndpointSecurity.validate(
                configuration.baseURL,
                policy: configuration.endpointSecurityPolicy
            )
        } else {
            url = try BoneInferenceEndpointSecurity.resolveAndValidate(
                baseURL: configuration.baseURL,
                endpoint: endpoint,
                policy: configuration.endpointSecurityPolicy
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyAuthentication(configuration, to: &request)
        let validatedFixedHeaders = try BoneInferenceHeaderPolicy.validated(fixedHeaders)
        let fixedNames = Set(validatedFixedHeaders.keys.map { $0.lowercased() })
        let authenticationFixedNames: Set<String> = configuration.authenticationMode == .bearerWithUserAgent
            ? ["user-agent"]
            : []
        let protectedNames = fixedNames.union(authenticationFixedNames)
        let validatedCustomHeaders = try BoneInferenceHeaderPolicy.validated(configuration.customHeaders)
        guard validatedCustomHeaders.keys.allSatisfy({ !protectedNames.contains($0.lowercased()) }) else {
            throw BoneInferenceTransportError.reservedHeader
        }
        for (name, value) in validatedCustomHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in validatedFixedHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    private static func applyAuthentication(
        _ configuration: BoneInferenceProviderConfiguration,
        to request: inout URLRequest
    ) throws {
        switch configuration.authenticationMode {
        case .bearer:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        case .bearerWithUserAgent:
            guard let userAgent = configuration.userAgent, !userAgent.isEmpty else {
                throw BoneInferenceTransportError.invalidConfiguration
            }
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        case .apiKey:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "api-key")
        case .anthropicDual:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        case .googleAPIKey:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
    }
}
