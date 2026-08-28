import Foundation

/// BoneAgentKit 的私有 Package 资源入口。
///
/// Bundle 名称和资源路径不是公共契约；外部调用方只能使用 Catalog 的语义接口。
enum Resources {
    static let bundle = Bundle.module

    static func data(
        forResource name: String,
        withExtension extensionName: String,
        subdirectory: String? = nil
    ) throws -> Data {
        guard let url = bundle.url(
            forResource: name,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) else {
            throw BoneInferenceProviderCatalog.Error.resourceMissing(name)
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}
