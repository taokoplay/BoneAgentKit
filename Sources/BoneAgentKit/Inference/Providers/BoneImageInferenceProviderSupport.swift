import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 图片协议特有的稳定错误；通用网络/端点错误由 BoneInferenceTransportError 表达。
public enum BoneImageInferenceProviderError: Error, Equatable, Sendable {
    case invalidCredential
    case invalidResponse
    case unsupportedRequest
}

enum BoneImageInferenceProviderSupport {
    static func makeRequest(
        configuration: BoneInferenceProviderConfiguration,
        path: String,
        authentication: BoneImageInferenceAuthentication,
        body: [String: Any]
    ) throws -> URLRequest {
        guard !configuration.apiKey.isEmpty else {
            throw BoneImageInferenceProviderError.invalidCredential
        }
        let url: URL
        do {
            url = try BoneInferenceEndpointSecurity.resolveAndValidate(
                baseURL: configuration.baseURL,
                endpoint: path,
                policy: configuration.endpointSecurityPolicy
            )
        } catch BoneInferenceTransportError.insecureEndpoint {
            throw BoneInferenceTransportError.invalidEndpoint
        } catch {
            throw BoneInferenceTransportError.invalidEndpoint
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch authentication {
        case .bearer:
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        case .googleAPIKey:
            request.setValue(configuration.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }
        let headers: [String: String]
        do {
            headers = try BoneInferenceHeaderPolicy.validated(configuration.customHeaders)
        } catch {
            throw BoneInferenceTransportError.reservedHeader
        }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let userAgent = configuration.userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func validatedJSON(_ response: BoneInferenceHTTPResponse) throws -> [String: Any] {
        guard (200 ... 299).contains(response.statusCode) else {
            throw BoneInferenceProviderResponseValidator.mappedError(
                statusCode: response.statusCode,
                data: response.data
            )
        }
        guard response.data.count <= BoneInferenceImageGenerationResponse.maximumInlineByteCount else {
            throw BoneInferenceTransportError.responseTooLarge
        }
        guard let json = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw BoneImageInferenceProviderError.invalidResponse
        }
        return json
    }

    static func payload(
        url value: Any?,
        base64 encoded: Any?,
        mimeType: Any? = nil
    ) throws -> BoneInferenceImagePayload? {
        if let value = value as? String,
           let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme)
        {
            return .remoteURL(url)
        }
        if let encoded = encoded as? String {
            let mediaType = try BoneInferenceImageMediaType(mimeType as? String ?? "image/png")
            return .base64(try BoneInferenceImageInlineBase64(data: encoded, mimeType: mediaType))
        }
        return nil
    }

    static func requirePayloads(
        _ payloads: [BoneInferenceImagePayload]
    ) throws -> BoneInferenceImageGenerationResponse {
        guard !payloads.isEmpty else { throw BoneImageInferenceProviderError.invalidResponse }
        return try BoneInferenceImageGenerationResponse(images: payloads)
    }
}

enum BoneImageInferenceAuthentication {
    case bearer
    case googleAPIKey
}
