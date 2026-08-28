import Foundation

/// BoneInference 自有 Provider 标识；不依赖 App 数据库或旧 AIProviderKit。
public enum BoneInferenceProviderKind: String, Codable, CaseIterable, Sendable {
    case anthropic = "Anthropic"
    case openAI = "OpenAI"
    case google = "Google"
    case zhipu = "Zhipu"
    case siliconFlow = "SiliconFlow"
    case newAPI = "NewApi"
    case custom = "Custom"
    case miniMax = "MiniMax"
    case agnes = "Agnes"
}

/// Provider 请求/响应协议变体。
public enum BoneInferenceProtocolVariant: String, Codable, CaseIterable, Sendable {
    case openAI
    case anthropicMessages
    case geminiGenerateContent
    case imagenPredict
    case minimaxImageGeneration
    case agnesImageGeneration
}

/// API Key 的请求头写入方式。
public enum BoneInferenceAuthenticationMode: String, Codable, Sendable {
    case bearer
    case anthropicDual
    case bearerWithUserAgent
    case apiKey
    case googleAPIKey
}

/// 最终请求端点的传输安全策略。
public enum BoneInferenceEndpointSecurityPolicy: Equatable, Sendable {
    /// 内置供应商只能使用 HTTPS。
    case builtIn
    /// 自定义服务可额外使用本机、回环和私网 HTTP。
    case custom
}

/// 推理请求执行所需的不可变 Provider 配置。
///
/// 凭据只能用于构造请求，不得进入日志、错误、事件或普通持久化。
public struct BoneInferenceProviderConfiguration: Equatable, Sendable {
    public let kind: BoneInferenceProviderKind
    public let apiKey: String
    public let baseURL: URL
    public let authenticationMode: BoneInferenceAuthenticationMode
    public let usesFullEndpointURL: Bool
    public let userAgent: String?
    public let customHeaders: [String: String]
    public let endpointOverrides: [String: String]
    public let endpointSecurityPolicy: BoneInferenceEndpointSecurityPolicy

    public init(
        kind: BoneInferenceProviderKind,
        apiKey: String,
        baseURL: URL,
        authenticationMode: BoneInferenceAuthenticationMode = .bearer,
        usesFullEndpointURL: Bool = false,
        userAgent: String? = nil,
        customHeaders: [String: String] = [:],
        endpointOverrides: [String: String] = [:],
        endpointSecurityPolicy: BoneInferenceEndpointSecurityPolicy = .builtIn
    ) {
        self.kind = kind
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.authenticationMode = authenticationMode
        self.usesFullEndpointURL = usesFullEndpointURL
        self.userAgent = userAgent
        self.customHeaders = customHeaders
        self.endpointOverrides = endpointOverrides
        self.endpointSecurityPolicy = endpointSecurityPolicy
    }
}
