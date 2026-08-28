import Foundation

/// 模型发现只证明远端 ID 可见；能力和协议元数据必须由本地 Catalog 合并。
public struct BoneInferenceModelDescriptor: Codable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: Set<BoneInferenceProviderCatalog.Capability>

    public init(
        id: String,
        displayName: String,
        capabilities: Set<BoneInferenceProviderCatalog.Capability> = []
    ) {
        self.id = id
        self.displayName = displayName
        self.capabilities = capabilities
    }
}

/// 可注入的统一模型发现边界。
public protocol BoneInferenceModelDiscovering: Sendable {
    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor]

    func fetchRaw(_ request: BoneInferenceRawModelListRequest) async throws -> Data
}

/// 自定义 Parser 使用的原始模型列表请求；只允许 GET query 或 POST JSON。
public struct BoneInferenceRawModelListRequest: Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case get = "GET"
        case post = "POST"
    }

    public let endpoint: URL
    public let method: Method
    public let query: [String: String]
    public let jsonBody: Data?

    public init(
        endpoint: URL,
        method: Method,
        query: [String: String] = [:],
        jsonBody: Data? = nil
    ) throws {
        guard query.keys.allSatisfy({ !$0.isEmpty }) else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        switch method {
        case .get:
            guard jsonBody == nil else {
                throw BoneInferenceTransportError.invalidConfiguration
            }
        case .post:
            guard query.isEmpty,
                  let jsonBody,
                  !jsonBody.isEmpty,
                  (try? JSONSerialization.jsonObject(with: jsonBody)) != nil else {
                throw BoneInferenceTransportError.invalidConfiguration
            }
        }
        self.endpoint = endpoint
        self.method = method
        self.query = query
        self.jsonBody = jsonBody
    }
}
