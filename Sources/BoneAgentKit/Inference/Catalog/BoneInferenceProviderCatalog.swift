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
        public let deprecated: Bool

        public init(
            id: String,
            displayName: String,
            capabilities: Set<Capability>,
            protocolVariant: BoneInferenceProtocolVariant,
            supportedImageSizes: [BoneInferenceImageSize] = [],
            supportedImageCounts: [Int] = [],
            generationOptions: BoneInferenceGenerationOptions = .init(),
            tokenLimits: BoneModelContextLimits? = nil,
            deprecated: Bool = false
        ) {
            self.id = id
            self.displayName = displayName
            self.capabilities = capabilities
            self.protocolVariant = protocolVariant
            self.supportedImageSizes = supportedImageSizes
            self.supportedImageCounts = supportedImageCounts
            self.generationOptions = generationOptions
            self.tokenLimits = tokenLimits
            self.deprecated = deprecated
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
        try BundledCatalogCache.shared.catalog()
    }

    /// 按语义 icon ID 与显示 scale 读取 PNG；不暴露 Bundle 或资源路径。
    public func iconData(iconID: String, scale: Int) throws -> Data {
        guard (1...3).contains(scale) else {
            throw Error.invalidIconScale(scale)
        }
        guard providers.contains(where: { $0.iconID == iconID }) else {
            throw Error.resourceMissing(iconID)
        }
        let suffix = scale == 1 ? "" : "@\(scale)x"
        return try Resources.data(
            forResource: "\(iconID)\(suffix)",
            withExtension: "png"
        )
    }

}

private final class BundledCatalogCache: @unchecked Sendable {
    static let shared = BundledCatalogCache()

    private let lock = NSLock()
    private var cached: BoneInferenceProviderCatalog?

    private init() {}

    func catalog() throws -> BoneInferenceProviderCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let decoded = try BoneInferenceProviderCatalog.decode(
            data: Resources.data(forResource: "AIProviderDefaults", withExtension: "json")
        )
        cached = decoded
        return decoded
    }
}
