import Foundation

/// Provider 与模型目录的统一入口。
///
/// 该服务只做聚合与转发：持有不可变目录，不保存凭据、不缓存发现结果、不写磁盘。
/// 每个方法都对应一个既有底层类型，Host 可以在一个对象上完成目录查询、模型列表与
/// 端点解析，同时保留 `BoneInferenceProviderModelListLoader` 或
/// `BoneInferenceModelDiscoveryClient` 直接注入依赖的能力。
///
/// 范围边界：推理执行仍使用 `BoneInferenceEngine` 实现，多轮与工具编排使用
/// `BoneAgent`，本地模型使用 `BoneAgentLocalModels`；本服务不代理这些域的会话、
/// 凭据、预算或持久化。
public final class BoneInferenceService: @unchecked Sendable {
    /// 服务可抛出的稳定错误。
    public enum Error: Swift.Error, Equatable, Sendable {
        /// 目录中不存在该 ident。
        case unknownProvider(String)
    }

    private let catalog: BoneInferenceProviderCatalog

    /// 使用指定目录创建服务；测试或自定义目录使用此入口。
    public init(catalog: BoneInferenceProviderCatalog) {
        self.catalog = catalog
    }

    /// 使用随包目录创建服务。
    public static func bundled() throws -> BoneInferenceService {
        BoneInferenceService(catalog: try .bundled())
    }

    /// 目录中的 Provider，顺序同 `sortOrder`。
    public func providers() -> [BoneInferenceProviderCatalog.Entry] {
        catalog.providers
    }

    /// 按稳定 ident 查询 Provider，大小写不敏感。
    public func provider(ident: String) -> BoneInferenceProviderCatalog.Entry? {
        catalog.provider(ident: ident)
    }

    /// 获取指定 Provider 的模型列表：先请求上游，失败回退内置模型。
    ///
    /// 未注入 discoverer 时使用默认 `BoneInferenceModelDiscoveryClient`；
    /// 需要自定义 Transport 时由 Host 自行构造并传入。
    public func modelList(
        forProvider ident: String,
        configuration: BoneInferenceProviderConfiguration,
        discoverer: (any BoneInferenceModelDiscovering)? = nil
    ) async throws -> BoneInferenceProviderModelList {
        guard let entry = provider(ident: ident) else {
            throw Error.unknownProvider(ident)
        }
        return try await modelList(
            for: entry,
            configuration: configuration,
            discoverer: discoverer
        )
    }

    /// 获取指定目录条目的模型列表：先请求上游，失败回退内置模型。
    public func modelList(
        for entry: BoneInferenceProviderCatalog.Entry,
        configuration: BoneInferenceProviderConfiguration,
        discoverer: (any BoneInferenceModelDiscovering)? = nil
    ) async throws -> BoneInferenceProviderModelList {
        try await BoneInferenceProviderModelListLoader(
            configuration: configuration,
            discoverer: discoverer ?? discoveryClient(configuration: configuration)
        ).load(for: entry)
    }

    /// 解析指定操作的上游地址；只做拼接，不联网、不校验传输安全策略。
    public func endpoint(
        for entry: BoneInferenceProviderCatalog.Entry,
        operation: String,
        modelID: String? = nil,
        overrideBaseURL: URL? = nil
    ) throws -> URL? {
        try entry.resolvedEndpoint(
            operation: operation,
            modelID: modelID,
            overrideBaseURL: overrideBaseURL
        )
    }

    /// 默认模型发现客户端；供 Host 需要底层描述符或自定义解析时直接使用。
    public func discoveryClient(
        configuration: BoneInferenceProviderConfiguration
    ) -> BoneInferenceModelDiscoveryClient {
        BoneInferenceModelDiscoveryClient(configuration: configuration)
    }
}
