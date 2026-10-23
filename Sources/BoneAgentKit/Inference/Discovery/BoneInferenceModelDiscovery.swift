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

/// 内部模型发现边界；不对外暴露第二套获取入口。
protocol BoneInferenceModelDiscovering: Sendable {
    func discover(
        using discovery: BoneInferenceProviderCatalog.Discovery
    ) async throws -> [BoneInferenceModelDescriptor]
}
