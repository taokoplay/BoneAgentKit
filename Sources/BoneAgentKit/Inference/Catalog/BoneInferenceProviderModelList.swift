import Foundation

/// 单个 Provider 的只读模型列表，合并内置声明与上游发现结果。
///
/// 该类型只做投影与合并，不联网、不持久化；需要请求上游时使用
/// `BoneInferenceProviderModelListLoader`，需要展示缓存时直接调用本类型初始化器。
/// `discoveryOutcome` 披露列表与实际上游状态的关系。
public struct BoneInferenceProviderModelList: Equatable, Sendable {
    /// 单个模型在本次列表中的来源；同时命中内置与远端时包含两个取值。
    public enum Origin: String, Codable, Hashable, Sendable {
        case catalog
        case discovery
    }

    /// 上游模型列表请求的实际结果。
    public enum DiscoveryOutcome: Equatable, Sendable {
        /// 没有 discoverer、没有可用模型列表端点，或 `manual` 目录不发起请求。
        case notRequested
        /// 上游返回了非空模型列表。
        case succeeded
        /// 上游请求以已知传输或解析错误失败。
        case transportFailure(BoneInferenceTransportError)
        /// 自定义 discoverer 抛出了非传输错误。
        case failed
    }

    /// 合并后的模型条目。
    public struct Model: Equatable, Sendable {
        public let id: String
        public let displayName: String
        public let origins: Set<Origin>
        public let capabilities: Set<BoneInferenceProviderCatalog.Capability>
        /// 目录 `chat` 操作解析出的上游地址；未声明或没有可用基址时为 `nil`。
        public let chatEndpoint: URL?
        /// 命中的内置声明；远端新发现为 `nil`，不代表能力缺失。
        public let catalogModel: BoneInferenceProviderCatalog.Model?

        public init(
            id: String,
            displayName: String,
            origins: Set<Origin>,
            capabilities: Set<BoneInferenceProviderCatalog.Capability>,
            chatEndpoint: URL?,
            catalogModel: BoneInferenceProviderCatalog.Model?
        ) {
            self.id = id
            self.displayName = displayName
            self.origins = origins
            self.capabilities = capabilities
            self.chatEndpoint = chatEndpoint
            self.catalogModel = catalogModel
        }
    }

    public let providerIdent: String
    public let providerTitle: String
    public let catalogMode: BoneInferenceProviderCatalog.CatalogMode
    /// Host 实际使用的基址；列表地址与模型端点都由它解析。
    public let baseURL: URL?
    public let models: [Model]
    /// 上游模型列表请求的结果；模型本身仍可能是回退后的内置列表。
    public let discoveryOutcome: DiscoveryOutcome

    /// 用内置目录与调用方缓存的发现结果构建列表，不发网络请求。
    ///
    /// 内置模型保持目录顺序，仅存在于远端的模型按发现顺序追加。
    public init(
        entry: BoneInferenceProviderCatalog.Entry,
        discovered: [BoneInferenceModelDescriptor] = [],
        baseURL: URL? = nil,
        discoveryOutcome: DiscoveryOutcome = .notRequested
    ) throws {
        let resolvedBaseURL = baseURL ?? entry.defaultBaseURL
        let discoveredIDs = Set(discovered.map(\.id))
        var seen = Set<String>()
        var models: [Model] = []
        models.reserveCapacity(entry.models.count + discovered.count)

        for model in entry.models {
            seen.insert(model.id)
            models.append(Model(
                id: model.id,
                displayName: model.displayName,
                origins: discoveredIDs.contains(model.id) ? [.catalog, .discovery] : [.catalog],
                capabilities: model.capabilities,
                chatEndpoint: try entry.resolvedEndpoint(
                    operation: "chat",
                    modelID: model.id,
                    overrideBaseURL: resolvedBaseURL
                ),
                catalogModel: model
            ))
        }

        for descriptor in discovered where seen.insert(descriptor.id).inserted {
            let trimmedName = descriptor.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            models.append(Model(
                id: descriptor.id,
                displayName: trimmedName.isEmpty ? descriptor.id : trimmedName,
                origins: [.discovery],
                capabilities: descriptor.capabilities,
                chatEndpoint: try entry.resolvedEndpoint(
                    operation: "chat",
                    modelID: descriptor.id,
                    overrideBaseURL: resolvedBaseURL
                ),
                catalogModel: nil
            ))
        }

        self.providerIdent = entry.ident
        self.providerTitle = entry.title
        self.catalogMode = entry.catalogMode
        self.baseURL = resolvedBaseURL
        self.models = models
        self.discoveryOutcome = discoveryOutcome
    }
}
