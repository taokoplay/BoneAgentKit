import Foundation

/// 获取单个 Provider 的模型列表：先请求上游，失败时回退目录内置模型。
///
/// 加载器是持有请求配置与可选 discoverer 的实例，避免把网络 I/O 挂在纯数据值类型上；
/// 只读缓存展示可直接构造 `BoneInferenceProviderModelList`，不经过本类型。
public struct BoneInferenceProviderModelListLoader: Sendable {
    private let configuration: BoneInferenceProviderConfiguration
    private let discoverer: (any BoneInferenceModelDiscovering)?

    public init(
        configuration: BoneInferenceProviderConfiguration,
        discoverer: (any BoneInferenceModelDiscovering)? = nil
    ) {
        self.configuration = configuration
        self.discoverer = discoverer
    }

    /// 先请求上游模型列表，失败时回退到目录内置模型。
    ///
    /// 只有目录基址或操作路径非法这类调用方配置错误会抛出；上游网络、HTTP 状态和
    /// 响应解析失败都转换为 `discoveryOutcome`，不中断列表展示。
    public func load(
        for entry: BoneInferenceProviderCatalog.Entry
    ) async throws -> BoneInferenceProviderModelList {
        guard entry.catalogMode != .manual,
              let discoverer,
              let discovery = try Self.discoverySource(
                  entry: entry,
                  baseURL: configuration.baseURL
              )
        else {
            return try BoneInferenceProviderModelList(
                entry: entry,
                baseURL: configuration.baseURL,
                discoveryOutcome: .notRequested
            )
        }

        do {
            let discovered = try await discoverer.discover(using: discovery)
            return try BoneInferenceProviderModelList(
                entry: entry,
                discovered: discovered,
                baseURL: configuration.baseURL,
                discoveryOutcome: .succeeded
            )
        } catch {
            let outcome: BoneInferenceProviderModelList.DiscoveryOutcome
            if let transportError = error as? BoneInferenceTransportError {
                outcome = .transportFailure(transportError)
            } else {
                outcome = .failed
            }
            return try BoneInferenceProviderModelList(
                entry: entry,
                baseURL: configuration.baseURL,
                discoveryOutcome: outcome
            )
        }
    }

    /// 优先使用目录声明的发现配置；缺失时回退到 `apiPaths.models` 的 OpenAI 列表协议。
    private static func discoverySource(
        entry: BoneInferenceProviderCatalog.Entry,
        baseURL: URL
    ) throws -> BoneInferenceProviderCatalog.Discovery? {
        if let discovery = entry.discovery {
            return discovery
        }
        guard let endpoint = try entry.resolvedEndpoint(
            operation: "models",
            overrideBaseURL: baseURL
        ) else {
            return nil
        }
        return .init(
            endpoint: endpoint,
            protocol: .openAI,
            authenticationMode: entry.authenticationMode
        )
    }
}
