import Foundation
import BoneAgentKit

/// Demo presentation adapter over the SDK's catalog and model-list service.
struct DemoChatCatalog: Sendable {
    let catalog: BoneInferenceProviderCatalog
    private let service: BoneInferenceService

    init() throws {
        self.init(catalog: try DemoChatProvider.bundledCatalog())
    }

    init(
        catalog: BoneInferenceProviderCatalog,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) {
        self.catalog = catalog
        service = BoneInferenceService(catalog: catalog, transport: transport)
    }

    /// Offline projection also works before a model or credential has been entered.
    func localModels(for settings: DemoLiveChatSettings) throws -> BoneInferenceProviderModelList {
        let entry = try settings.provider.catalogEntry(in: catalog)
        let baseURL = DemoLiveChatSettings.connectionURL(settings.baseURL) ?? entry.defaultBaseURL
        return try BoneInferenceProviderModelList(entry: entry, baseURL: baseURL)
    }

    func modelList(
        for settings: DemoLiveChatSettings,
        apiKey: String
    ) async throws -> BoneInferenceProviderModelList {
        try Task.checkCancellation()
        let entry = try settings.provider.catalogEntry(in: catalog)
        let configuration = try settings.discoveryConfiguration(apiKey: apiKey)
        let list = try await service.modelList(forProvider: entry.ident, configuration: configuration)
        // The SDK deliberately converts discovery errors (including cancellation)
        // into fallback lists. A cancelled UI refresh must never publish that result.
        try Task.checkCancellation()
        return list
    }

    static func chatModels(
        in list: BoneInferenceProviderModelList
    ) -> [BoneInferenceProviderModelList.Model] {
        list.models.filter {
            $0.catalogModel?.deprecated != true
                && ($0.capabilities.contains(.chat) || $0.capabilities.isEmpty)
        }
    }

    func iconData(for provider: DemoChatProvider, scale: Int = 3) throws -> Data {
        let entry = try provider.catalogEntry(in: catalog)
        return try catalog.iconData(iconID: entry.iconID, scale: scale)
    }
}
