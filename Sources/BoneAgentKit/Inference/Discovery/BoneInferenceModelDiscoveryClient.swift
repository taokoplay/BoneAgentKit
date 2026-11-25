import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// 使用 BoneInference Transport 执行 Catalog 声明与自定义 Raw 模型发现。
struct BoneInferenceModelDiscoveryClient: BoneInferenceModelDiscovering, Sendable {
    private static let maximumTimeout: TimeInterval = 15
    private static let compatibleTimeout: TimeInterval = 12

    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport
    private let compatible: BoneInferenceCompatibleDiscovery?

    init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport(),
        compatible: BoneInferenceCompatibleDiscovery? = nil
    ) {
        self.configuration = configuration
        self.transport = transport
        self.compatible = compatible
    }

    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        guard let compatible else { return try await fetch(using: discovery) }
        return try await withThrowingTaskGroup(of: [BoneInferenceModelDescriptor].self) { group in
            group.addTask {
                do {
                    return try await fetch(using: discovery)
                } catch {
                    try Task.checkCancellation()
                    guard error as? BoneInferenceTransportError != .cancelled,
                          let endpoint = compatible.fallback(after: discovery.endpoint) else { throw error }
                    return try await fetch(using: .init(
                        endpoint: endpoint, protocol: discovery.protocol,
                        authenticationMode: discovery.authenticationMode
                    ))
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(Self.compatibleTimeout * 1_000_000_000))
                throw BoneInferenceTransportError.network(.init(error: URLError(.timedOut) as NSError))
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw BoneInferenceTransportError.cancelled }
            return result
        }
    }

    private func fetch(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor] {
        try Task.checkCancellation()
        // Agnes 的模型列表属于用户配置的站点，不将国际/网关凭据发送至内置国内地址。
        let endpoint: URL
        if compatible == nil, configuration.kind == .agnes {
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
        let response: BoneInferenceHTTPResponse
        if compatible == nil {
            response = try await transport.sendRetryableForModels(request)
        } else {
            response = try await transport.send(request)
        }
        try Task.checkCancellation()
        let json: [String: Any]
        if compatible != nil, (200...299).contains(response.statusCode),
           let rows = try? JSONSerialization.jsonObject(with: response.data) as? [[String: Any]] {
            json = ["data": rows]
        } else {
            json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        }
        try Self.validateGatewayEnvelope(json)
        let descriptors = ModelDiscoveryParser.parse(json, protocol: discovery.protocol, compatible: compatible != nil)
        guard !descriptors.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return descriptors
    }

    /// 部分兼容网关在 HTTP 200 内返回 `success: false` 和业务错误码；不能当成空列表。
    private static func validateGatewayEnvelope(_ json: [String: Any]) throws {
        guard let success = json["success"] as? Bool, !success else {
            return
        }
        let code = (json["code"] as? Int)
            ?? (json["code"] as? String).flatMap(Int.init)
        guard let code else {
            throw BoneInferenceTransportError.invalidResponse
        }
        if code == 1001 {
            throw BoneInferenceTransportError.invalidCredential
        }
        throw BoneInferenceProviderResponseValidator.mappedError(statusCode: code)
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
            authenticationMode: compatible == .anthropic ? .anthropicDual : authenticationMode,
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
            fixedHeaders: fixedHeaders,
            allowsAnonymous: compatible != nil
        )
        if compatible == .anthropic { request.setValue(nil, forHTTPHeaderField: "Authorization") }
        let timeout = compatible == nil ? Self.maximumTimeout : Self.compatibleTimeout
        request.timeoutInterval = min(request.timeoutInterval, timeout)
        return request
    }
}

/// 内部协议解析器；不公开第二套 Parser 类型。
enum ModelDiscoveryParser {
    static func parse(
        _ json: [String: Any],
        protocol protocolKind: BoneInferenceProviderCatalog.Discovery.ProtocolKind,
        compatible: Bool = false
    ) -> [BoneInferenceModelDescriptor] {
        let entries: [[String: Any]]
        if compatible, let rows = (json["data"] as? [[String: Any]]) ?? (json["models"] as? [[String: Any]]) {
            entries = rows
        } else {
            switch protocolKind {
            case .openAI:
                entries = modelArray(from: json)
            case .anthropic, .miniMax:
                entries = json["data"] as? [[String: Any]] ?? []
            case .google:
                entries = json["models"] as? [[String: Any]] ?? []
            }
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
            var id = rawID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if compatible && id.isEmpty {
                id = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if protocolKind == .google, id.hasPrefix("models/") {
                id.removeFirst("models/".count)
            }
            guard !id.isEmpty, seen.insert(id).inserted else { return nil }
            let name = rawDisplayName ?? (compatible ? entry["display_name"] as? String : nil)
            let displayName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
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
