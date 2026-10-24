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
    ///
    /// 实现 `LocalizedError`，让 Host 直接展示 `localizedDescription` 时也能看到供应商与字段，
    /// 不再退化成 `BoneInferenceProviderCatalog.Error 错误 7` 这类只含 case 序号的文案。
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
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

extension BoneInferenceProviderCatalog.Error {
    /// 面向用户的中文错误说明；只包含目录字段与标识，不含凭据或请求内容。
    public var errorDescription: String? {
        switch self {
        case let .resourceMissing(name):
            return "缺少内置资源 \(name)。"
        case let .invalidIconScale(scale):
            return "图标显示倍率 \(scale) 不受支持。"
        case let .unsupportedSchema(version):
            return "供应商目录 schemaVersion \(version) 不受支持，当前只接受 1。"
        case let .duplicateProvider(provider):
            return "供应商 \(provider) 在目录中重复声明。"
        case let .missingParent(provider: provider, parent: parent):
            return "供应商 \(provider) 继承的父供应商 \(parent) 不存在。"
        case let .inheritanceCycle(providers):
            return "供应商继承出现循环：\(providers.joined(separator: " → "))。"
        case let .missingField(provider: provider, field: field):
            return "供应商 \(provider) 缺少必需字段 \(field)。"
        case let .invalidURL(provider: provider, field: field):
            return "供应商 \(provider) 的 \(field) 不是合法的 https 地址。"
        case let .unknownProviderProtocol(provider: provider, value: value):
            return "供应商 \(provider) 的协议 \(value) 不受支持。"
        case let .unknownAuthenticationMode(provider: provider, value: value):
            return "供应商 \(provider) 的认证方式 \(value) 不受支持。"
        case let .unknownCatalogMode(provider: provider, value: value):
            return "供应商 \(provider) 的目录模式 \(value) 不受支持。"
        case let .unknownDiscoveryProtocol(provider: provider, value: value):
            return "供应商 \(provider) 的模型发现协议 \(value) 不受支持。"
        case let .discoveryNotAllowed(provider: provider, mode: mode):
            return "供应商 \(provider) 的目录模式 \(mode) 不允许声明模型发现端点。"
        case let .unknownProtocolVariant(provider: provider, modelID: modelID, value: value):
            return "供应商 \(provider) 的模型 \(modelID) 使用了不受支持的协议变体 \(value)。"
        case let .unknownCapability(provider: provider, modelID: modelID, value: value):
            return "供应商 \(provider) 的模型 \(modelID) 声明了不受支持的能力 \(value)。"
        case let .duplicateModel(provider: provider, modelID: modelID):
            return "供应商 \(provider) 的模型 \(modelID) 重复声明。"
        case let .missingCapability(provider: provider, modelID: modelID):
            return "供应商 \(provider) 的模型 \(modelID) 缺少必需的能力声明。"
        case let .invalidModelParameter(provider: provider, modelID: modelID, field: field):
            return "供应商 \(provider) 的模型 \(modelID) 的参数 \(field) 不合法。"
        case let .invalidModelTokenLimit(provider: provider, modelID: modelID, field: field):
            return "供应商 \(provider) 的模型 \(modelID) 的 Token 限制字段 \(field) 不合法。"
        case let .invalidImageSize(provider: provider, modelID: modelID):
            return "供应商 \(provider) 的模型 \(modelID) 声明了不合法的图片尺寸。"
        case let .invalidImageCount(provider: provider, modelID: modelID, value: value):
            return "供应商 \(provider) 的模型 \(modelID) 的图片数量 \(value) 不合法。"
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
