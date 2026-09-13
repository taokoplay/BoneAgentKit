import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 使用 BoneInference Transport 执行 Catalog 声明与自定义 Raw 模型发现。
public struct BoneInferenceModelDiscoveryClient: BoneInferenceModelDiscovering, Sendable {
    private static let maximumTimeout: TimeInterval = 15

    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    /// 从当前 Agnes Base URL 获取模型 ID/名称；不提供内置回退或推断 Token 限制。
    public func discoverAgnesModels() async throws -> [BoneInferenceModelDescriptor] {
        guard configuration.kind == .agnes, !configuration.usesFullEndpointURL else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        return try await discover(using: .init(
            endpoint: configuration.baseURL.appendingPathComponent("models"),
            protocol: .openAI,
            authenticationMode: configuration.authenticationMode
        ))
    }

    public func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        // Agnes 的模型列表属于用户配置的站点，不将国际/网关凭据发送至内置国内地址。
        let endpoint: URL
        if configuration.kind == .agnes {
            guard !configuration.usesFullEndpointURL else {
                throw BoneInferenceTransportError.invalidConfiguration
            }
            endpoint = configuration.baseURL.appendingPathComponent("models")
        } else {
            endpoint = discovery.endpoint
        }
        let request = try makeRequest(
            endpoint: endpoint,
            method: "GET",
            authenticationMode: discovery.authenticationMode,
            fixedHeaders: discovery.protocol == .anthropic
                ? ["anthropic-version": "2023-06-01"]
                : [:]
        )
        let response = try await transport.sendRetryableForModels(request)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        let descriptors = ModelDiscoveryParser.parse(json, protocol: discovery.protocol)
        guard !descriptors.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return descriptors
    }

    public func fetchRaw(_ raw: BoneInferenceRawModelListRequest) async throws -> Data {
        var request = try makeRequest(
            endpoint: raw.endpoint,
            method: raw.method.rawValue,
            authenticationMode: configuration.authenticationMode,
            fixedHeaders: [:]
        )
        switch raw.method {
        case .get:
            guard var components = URLComponents(
                url: request.url!,
                resolvingAgainstBaseURL: false
            ) else {
                throw BoneInferenceTransportError.invalidEndpoint
            }
            let items = raw.query.sorted { $0.key < $1.key }.map {
                URLQueryItem(name: $0.key, value: $0.value)
            }
            components.queryItems = (components.queryItems ?? []) + items
            guard let url = components.url else {
                throw BoneInferenceTransportError.invalidEndpoint
            }
            request.url = url
        case .post:
            request.httpBody = raw.jsonBody
        }
        let response: BoneInferenceHTTPResponse
        switch raw.method {
        case .get:
            response = try await transport.sendRetryableForModels(request)
        case .post:
            response = try await transport.send(request)
        }
        guard (200...299).contains(response.statusCode) else {
            throw BoneInferenceProviderResponseValidator.mappedError(
                statusCode: response.statusCode
            )
        }
        guard !response.data.isEmpty,
              (try? JSONSerialization.jsonObject(with: response.data)) != nil else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return response.data
    }

    private func makeRequest(
        endpoint: URL,
        method: String,
        authenticationMode: BoneInferenceAuthenticationMode,
        fixedHeaders: [String: String]
    ) throws -> URLRequest {
        let endpoint = try BoneInferenceEndpointSecurity.validate(
            endpoint,
            policy: configuration.endpointSecurityPolicy
        )
        let requestConfiguration = BoneInferenceProviderConfiguration(
            kind: configuration.kind,
            apiKey: configuration.apiKey,
            baseURL: endpoint,
            authenticationMode: authenticationMode,
            usesFullEndpointURL: true,
            userAgent: configuration.userAgent,
            customHeaders: configuration.customHeaders,
            endpointSecurityPolicy: configuration.endpointSecurityPolicy
        )
        var request = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: requestConfiguration,
            operation: "models",
            defaultPath: endpoint.absoluteString,
            method: method,
            usesFullEndpointURL: true,
            fixedHeaders: fixedHeaders
        )
        request.timeoutInterval = min(request.timeoutInterval, Self.maximumTimeout)
        return request
    }
}

/// 内部协议解析器；不公开第二套 Parser 类型。
enum ModelDiscoveryParser {
    static func parse(
        _ json: [String: Any],
        protocol protocolKind: BoneInferenceProviderCatalog.Discovery.ProtocolKind
    ) -> [BoneInferenceModelDescriptor] {
        let entries: [[String: Any]]
        switch protocolKind {
        case .openAI:
            entries = modelArray(from: json)
        case .anthropic, .miniMax:
            entries = json["data"] as? [[String: Any]] ?? []
        case .google:
            entries = json["models"] as? [[String: Any]] ?? []
        }

        var seen = Set<String>()
        return entries.compactMap { entry in
            let rawID: String?
            let rawDisplayName: String?
            switch protocolKind {
            case .openAI:
                rawID = (entry["id"] ?? entry["model_id"]) as? String
                rawDisplayName = (entry["name"] ?? entry["model_name"]) as? String
            case .anthropic:
                rawID = entry["id"] as? String
                rawDisplayName = (entry["display_name"] ?? entry["name"]) as? String
            case .google:
                rawID = entry["name"] as? String
                rawDisplayName = entry["displayName"] as? String
            case .miniMax:
                rawID = entry["id"] as? String
                rawDisplayName = entry["name"] as? String
            }
            guard var id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty else { return nil }
            if protocolKind == .google, id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let displayName = rawDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return BoneInferenceModelDescriptor(
                id: id,
                displayName: displayName?.isEmpty == false ? displayName! : id
            )
        }
    }

    private static func modelArray(from json: [String: Any]) -> [[String: Any]] {
        if let data = json["data"] as? [[String: Any]] { return data }
        if let result = json["result"] as? [String: Any],
           let data = result["data"] as? [[String: Any]] {
            return data
        }
        return []
    }
}
