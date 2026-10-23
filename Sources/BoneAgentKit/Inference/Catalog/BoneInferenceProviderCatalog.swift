import BoneAgentProviderAssets
import Foundation

/// 版本化 Provider/Model 目录，是 BoneInference 唯一公开目录 Interface。
public struct BoneInferenceProviderCatalog: Equatable, Sendable {
    /// 目录中的请求协议类别。
    public enum ProviderProtocol: String, Codable, Sendable {
        case openAI
        case anthropic
        case google
        case newAPI
        case customOpenAI
    }

    /// 模型目录来源。
    public enum CatalogMode: String, Codable, Sendable {
        case local
        case remote
        case manual
    }

    /// 模型明确声明的能力。
    public enum Capability: String, Codable, Hashable, Sendable {
        case chat
        case image
    }

    /// 目录中声明的官方模型发现配置。
    public struct Discovery: Equatable, Sendable {
        public enum ProtocolKind: String, Codable, Sendable {
            case openAI
            case anthropic
            case google
            case miniMax
        }

        public let endpoint: URL
        public let `protocol`: ProtocolKind
        public let authenticationMode: BoneInferenceAuthenticationMode

        public init(
            endpoint: URL,
            protocol: ProtocolKind,
            authenticationMode: BoneInferenceAuthenticationMode
        ) {
            self.endpoint = endpoint
            self.protocol = `protocol`
            self.authenticationMode = authenticationMode
        }
    }

    /// 目录中的单个模型定义。
    public struct Model: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let capabilities: Set<Capability>
        public let protocolVariant: BoneInferenceProtocolVariant
        public let supportedImageSizes: [BoneInferenceImageSize]
        public let supportedImageCounts: [Int]
        public let generationOptions: BoneInferenceGenerationOptions
        public let tokenLimits: BoneModelContextLimits?
        /// 有证据的模型级推理能力；nil 表示目录尚无可核验结论。
        public let inferenceCapabilityProfile: BoneModelCapabilityProfile?
        public let deprecated: Bool
        /// 外部目录声明，与已验证能力和官方执行预算分离。
        public let metadata: BoneModelMetadata?

        public init(
            id: String,
            displayName: String,
            capabilities: Set<Capability>,
            protocolVariant: BoneInferenceProtocolVariant,
            supportedImageSizes: [BoneInferenceImageSize] = [],
            supportedImageCounts: [Int] = [],
            generationOptions: BoneInferenceGenerationOptions = .init(),
            tokenLimits: BoneModelContextLimits? = nil,
            inferenceCapabilityProfile: BoneModelCapabilityProfile? = nil,
            deprecated: Bool = false,
            metadata: BoneModelMetadata? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.capabilities = capabilities
            self.protocolVariant = protocolVariant
            self.supportedImageSizes = supportedImageSizes
            self.supportedImageCounts = supportedImageCounts
            self.generationOptions = generationOptions
            self.tokenLimits = tokenLimits
            self.inferenceCapabilityProfile = inferenceCapabilityProfile
            self.deprecated = deprecated
            self.metadata = metadata
        }
    }

    /// 已展开继承并完成校验的 Provider 定义。
    public struct Entry: Equatable, Sendable {
        public let ident: String
        public let title: String
        public let iconID: String
        public let providerKind: BoneInferenceProviderKind
        public let providerProtocol: ProviderProtocol
        public let authenticationMode: BoneInferenceAuthenticationMode
        public let defaultBaseURL: URL?
        public let inviteURL: URL?
        public let documentationURL: URL?
        public let catalogMode: CatalogMode
        public let sortOrder: Int
        public let apiPaths: [String: String]
        public let discovery: Discovery?
        public let models: [Model]

        public init(
            ident: String,
            title: String,
            iconID: String,
            providerKind: BoneInferenceProviderKind,
            providerProtocol: ProviderProtocol,
            authenticationMode: BoneInferenceAuthenticationMode,
            defaultBaseURL: URL?,
            inviteURL: URL?,
            documentationURL: URL?,
            catalogMode: CatalogMode,
            sortOrder: Int,
            apiPaths: [String: String],
            discovery: Discovery?,
            models: [Model]
        ) {
            self.ident = ident
            self.title = title
            self.iconID = iconID
            self.providerKind = providerKind
            self.providerProtocol = providerProtocol
            self.authenticationMode = authenticationMode
            self.defaultBaseURL = defaultBaseURL
            self.inviteURL = inviteURL
            self.documentationURL = documentationURL
            self.catalogMode = catalogMode
            self.sortOrder = sortOrder
            self.apiPaths = apiPaths
            self.discovery = discovery
            self.models = models
        }
    }

    /// Catalog 解码、校验或资源读取错误。
    public enum Error: Swift.Error, Equatable, Sendable {
        case resourceMissing(String)
        case invalidIconScale(Int)
        case unsupportedSchema(Int)
        case duplicateProvider(String)
        case missingParent(provider: String, parent: String)
        case inheritanceCycle([String])
        case missingField(provider: String, field: String)
        case invalidURL(provider: String, field: String)
        case unknownProviderProtocol(provider: String, value: String)
        case unknownAuthenticationMode(provider: String, value: String)
        case unknownCatalogMode(provider: String, value: String)
        case unknownDiscoveryProtocol(provider: String, value: String)
        case discoveryNotAllowed(provider: String, mode: String)
        case unknownProtocolVariant(provider: String, modelID: String, value: String)
        case unknownCapability(provider: String, modelID: String, value: String)
        case duplicateModel(provider: String, modelID: String)
        case missingCapability(provider: String, modelID: String)
        case invalidModelParameter(provider: String, modelID: String, field: String)
        case invalidModelTokenLimit(provider: String, modelID: String, field: String)
        case invalidImageSize(provider: String, modelID: String)
        case invalidImageCount(provider: String, modelID: String, value: Int)
    }

    public let schemaVersion: Int
    public let catalogVersion: Int
    public let verifiedAt: String
    public let providers: [Entry]

    public init(
        schemaVersion: Int,
        catalogVersion: Int,
        verifiedAt: String,
        providers: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.verifiedAt = verifiedAt
        self.providers = providers
    }

    /// 按稳定 ident 查询目录条目，查询不区分大小写。
    public func provider(ident: String) -> Entry? {
        providers.first { $0.ident.caseInsensitiveCompare(ident) == .orderedSame }
    }

    /// 从 Kit 私有资源加载并缓存唯一内置目录。
    public static func bundled() throws -> Self {
        try BundledCatalog.value.get()
    }

    /// 按稳定语义 icon ID 与显示倍率读取内置渠道 PNG。
    public func iconData(iconID: String, scale: Int) throws -> Data {
        do {
            return try BoneAgentProviderAssets.iconData(iconID: iconID, scale: scale)
        } catch let error as BoneAgentProviderAssets.Error {
            switch error {
            case let .invalidScale(scale):
                throw Error.invalidIconScale(scale)
            case let .unknownIconID(iconID):
                throw Error.resourceMissing(iconID)
            case let .resourceMissing(iconID, _):
                throw Error.resourceMissing(iconID)
            }
        }
    }
}

/// 目录条目的只读上游地址投影。
public extension BoneInferenceProviderCatalog.Entry {
    /// 返回目录声明的操作端点与基址拼接后的 URL。
    ///
    /// - Parameters:
    ///   - operation: `apiPaths` 中的操作名，例如 `chat`、`image`、`models`。
    ///   - modelID: 传入时替换路径里的 `{model}` 占位符。
    ///   - overrideBaseURL: Host 实际使用的基址；缺省回退到 `defaultBaseURL`。
    /// - Returns: 未声明该操作、路径为空或没有可用基址时返回 `nil`。
    ///
    /// 路径支持 `{origin}`（基址的 scheme/host/port），用于模型列表固定在站点根路径、
    /// 但对话端点带前缀的供应商。这里只做拼接，不校验传输安全策略，也不发请求。
    func resolvedEndpoint(
        operation: String,
        modelID: String? = nil,
        overrideBaseURL: URL? = nil
    ) throws -> URL? {
        guard let endpoint = apiPaths[operation], !endpoint.isEmpty else {
            return nil
        }
        guard let baseURL = overrideBaseURL ?? defaultBaseURL else {
            return nil
        }
        var path = endpoint.replacingOccurrences(of: "{model}", with: modelID ?? "{model}")
        if path.contains("{origin}") {
            path = path.replacingOccurrences(of: "{origin}", with: try originString(of: baseURL))
        }
        return try BoneInferenceEndpointSecurity.resolvedURL(baseURL: baseURL, endpoint: path)
    }

    private func originString(of baseURL: URL) throws -> String {
        var components = URLComponents()
        components.scheme = baseURL.scheme
        components.host = baseURL.host
        components.port = baseURL.port
        guard let origin = components.string, !origin.isEmpty else {
            throw BoneInferenceTransportError.invalidEndpoint
        }
        return origin
    }
}

private enum BundledCatalog {
    /// 静态常量由 Swift 保证一次性线程安全初始化；目录不可变，因此不需要锁或可变缓存。
    static let value: Result<BoneInferenceProviderCatalog, Swift.Error> = Result {
        try BoneInferenceProviderCatalog.decode(
            data: Resources.data(forResource: "AIProviderDefaults", withExtension: "json")
        )
    }
}
