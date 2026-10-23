import Foundation

/// Provider 目录与模型列表的唯一公开入口。
///
/// 服务持有不可变目录和可注入的 HTTP Transport，不保存凭据、不缓存发现结果、不写磁盘。
/// 获取模型列表统一调用 `modelList(forProvider:configuration:)`：先请求上游，失败回退内置目录。
/// 需要代理或自定义网络时通过初始化器注入 Transport，而不是另建并行的发现入口。
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
    private let transport: any BoneInferenceHTTPTransport

    /// 使用指定目录和 Transport 创建服务；测试或自定义网络使用此入口。
    public init(
        catalog: BoneInferenceProviderCatalog,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) {
        self.catalog = catalog
        self.transport = transport
    }

    /// 使用随包目录创建服务。
    public static func bundled(
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) throws -> BoneInferenceService {
        BoneInferenceService(catalog: try .bundled(), transport: transport)
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
    public func modelList(
        forProvider ident: String,
        configuration: BoneInferenceProviderConfiguration
    ) async throws -> BoneInferenceProviderModelList {
        guard let entry = provider(ident: ident) else {
            throw Error.unknownProvider(ident)
        }
        return try await modelList(for: entry, configuration: configuration)
    }

    func modelList(
        for entry: BoneInferenceProviderCatalog.Entry,
        configuration: BoneInferenceProviderConfiguration
    ) async throws -> BoneInferenceProviderModelList {
        try await BoneInferenceProviderModelListLoader(
            configuration: configuration,
            discoverer: BoneInferenceModelDiscoveryClient(
                configuration: configuration,
                transport: transport
            )
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
}
