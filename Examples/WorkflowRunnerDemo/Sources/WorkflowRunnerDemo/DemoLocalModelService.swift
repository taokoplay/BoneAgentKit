import Foundation
import BoneAgentLocalModels

struct DemoLocalModelEntry: Identifiable, Sendable {
    let model: BoneLocalModelDescriptor
    let installation: BoneLocalModelInstallationState
    let download: BoneLocalModelDownloadState
    let storedByteCount: Int64?

    var id: String { model.id }
    var hasStoredAsset: Bool { storedByteCount != nil }
    var isInstalled: Bool {
        if case .installed = installation { return true }
        return false
    }
}

struct DemoLocalModelSnapshot: Sendable {
    let entries: [DemoLocalModelEntry]
    let environment: BoneLocalRuntimeEnvironment
    let storageURL: URL
    let catalogVersion: Int?
    let catalogRuntimeVersion: Int?
    let networkEnabled: Bool
    let catalogIssue: String?
}

struct DemoLocalModelProbe: Sendable {
    let report: BoneLocalRuntimeProbeReport
    let checkedAt: Date
}

enum DemoLocalModelServiceError: Error, LocalizedError, Equatable {
    case catalogTooLarge
    case tooManyModels
    case installedCatalogConflict
    case unknownModel
    case busy
    case alreadyStored
    case notStored
    case networkDisabled

    var errorDescription: String? {
        switch self {
        case .catalogTooLarge: return "目录 JSON 最多 1 MiB。"
        case .tooManyModels: return "本实验每份目录最多管理 64 个模型。"
        case .installedCatalogConflict:
            return "新目录移除或修改了已有本地文件的模型。请保留这些条目的完整元数据，或先删除对应的 SDK 托管文件。"
        case .unknownModel: return "模型不在当前已验证的目录中。"
        case .busy: return "请等待当前操作结束或取消下载后重试。"
        case .alreadyStored: return "此模型已有本地文件；重新下载前请先确认删除。"
        case .notStored: return "没有可操作的 SDK 托管模型文件。"
        case .networkDisabled: return "离线 UI 测试模式：网络下载已禁用。"
        }
    }
}

/// Owns one SDK Store/coordinator. All filesystem work runs on this actor, away
/// from SwiftUI. Catalog metadata and SDK artifacts share an app-owned parent.
actor DemoLocalModelService {
    static let maximumCatalogBytes = 1_048_576
    static let maximumModels = 64

    private let store: BoneLocalModelStore
    private let coordinator: BoneLocalModelDownloadCoordinator
    private let catalogURL: URL
    private let environmentProvider: @Sendable (URL) throws -> BoneLocalRuntimeEnvironment
    private let networkEnabled: Bool
    private var catalog: BoneLocalModelCatalog?
    private var catalogIssue: String?
    private var activeDownloadID: String?

    init(
        rootURL: URL,
        transport: any BoneLocalModelDownloadTransport,
        environmentProvider: @escaping @Sendable (URL) throws -> BoneLocalRuntimeEnvironment = {
            try BoneLocalRuntimeEnvironment.current(storageURL: $0)
        },
        networkEnabled: Bool = true,
        restoresCatalog: Bool = true
    ) throws {
        let store = try BoneLocalModelStore(rootURL: rootURL.appendingPathComponent("Models", isDirectory: true))
        self.store = store
        coordinator = BoneLocalModelDownloadCoordinator(store: store, transport: transport)
        catalogURL = rootURL.appendingPathComponent("catalog.json")
        self.environmentProvider = environmentProvider
        self.networkEnabled = networkEnabled
        if restoresCatalog, FileManager.default.fileExists(atPath: catalogURL.path) {
            do { catalog = try Self.decodeCatalog(Self.readBoundedCatalog(at: catalogURL)) }
            catch {
                catalogIssue = "保存的目录读取失败，请重新导入可信目录。\n\(String(String(reflecting: error).prefix(2_048)))"
            }
        }
        // Startup only, before this owner permits any operations.
        try store.cleanIncompleteDownloads()
    }

    static func openDefault(isUITesting: Bool) async throws -> DemoLocalModelService {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let root = support.appendingPathComponent("AgentLabLocalModels", isDirectory: true)
        if isUITesting {
            return try DemoLocalModelService(
                rootURL: root.appendingPathComponent("UITests", isDirectory: true),
                transport: OfflineTransport(), networkEnabled: false, restoresCatalog: false
            )
        }
        return try DemoLocalModelService(
            rootURL: root, transport: BoneURLSessionLocalModelDownloadTransport()
        )
    }

    func snapshot() async throws -> DemoLocalModelSnapshot {
        let environment = try environmentProvider(store.rootURL)
        let currentCatalog = catalog
        var entries: [DemoLocalModelEntry] = []
        for model in currentCatalog?.models ?? [] {
            entries.append(.init(
                model: model,
                installation: store.installationState(for: model, verifyChecksum: false),
                download: await coordinator.state(for: model.id),
                storedByteCount: storedBytes(for: model)
            ))
        }
        return .init(
            entries: entries, environment: environment, storageURL: store.rootURL,
            catalogVersion: currentCatalog?.catalogVersion,
            catalogRuntimeVersion: currentCatalog?.runtimeVersion,
            networkEnabled: networkEnabled, catalogIssue: catalogIssue
        )
    }

    func importCatalog(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try importCatalog(data: Self.readBoundedCatalog(at: url))
    }

    func importCatalog(data: Data) throws {
        guard activeDownloadID == nil else { throw DemoLocalModelServiceError.busy }
        try Task.checkCancellation()
        let replacement = try Self.decodeCatalog(data)
        // A replacement must not orphan installed inventory or silently reassign
        // an installed file to a different checksum/descriptor.
        for model in catalog?.models ?? [] where storedBytes(for: model) != nil {
            guard replacement.model(id: model.id) == model else {
                throw DemoLocalModelServiceError.installedCatalogConflict
            }
        }
        try data.write(to: catalogURL, options: .atomic)
        catalog = replacement
        catalogIssue = nil
    }

    func download(modelID: String, allowsCellularAccess: Bool) async throws {
        guard networkEnabled else { throw DemoLocalModelServiceError.networkDisabled }
        guard activeDownloadID == nil else { throw DemoLocalModelServiceError.busy }
        let model = try model(for: modelID)
        guard storedBytes(for: model) == nil else { throw DemoLocalModelServiceError.alreadyStored }
        try Task.checkCancellation()
        // SDK disk preflight uses a fresh reading, not the last rendered snapshot.
        let environment = try environmentProvider(store.rootURL)
        activeDownloadID = model.id
        defer { activeDownloadID = nil }
        try await coordinator.download(
            model, environment: environment,
            policy: .init(allowsCellularAccess: allowsCellularAccess)
        )
    }

    func cancelDownload(modelID: String) async {
        await coordinator.cancel(modelID: modelID)
    }

    func delete(modelID: String) throws {
        guard activeDownloadID == nil else { throw DemoLocalModelServiceError.busy }
        let model = try model(for: modelID)
        guard storedBytes(for: model) != nil else { throw DemoLocalModelServiceError.notStored }
        try Task.checkCancellation()
        // Only a descriptor-backed regular file inside this Store is eligible.
        try store.removeModel(model)
    }

    func inspect(modelID: String) throws -> DemoLocalModelProbe {
        guard activeDownloadID == nil else { throw DemoLocalModelServiceError.busy }
        let model = try model(for: modelID)
        guard storedBytes(for: model) != nil else { throw DemoLocalModelServiceError.notStored }
        try Task.checkCancellation()
        let environment = try environmentProvider(store.rootURL)
        let inspection = BoneLocalModelArtifactInspector.inspect(model: model, store: store, verifyChecksum: true)
        var checks = inspection.checks
        checks.append(.init(
            kind: .deviceMemory,
            status: environment.physicalMemoryBytes >= model.minimumMemoryBytes ? .passed : .incompatible
        ))
        // There is no executable backend in this demo. No adapter, constraints,
        // successful load, smoke result, or generation capability is fabricated.
        checks.append(.init(kind: .adapterAvailability, status: .unsupported))
        return .init(
            report: .init(modelID: model.id, adapterID: "not-configured", depth: .metadata, checks: checks),
            checkedAt: Date()
        )
    }

    private func model(for id: String) throws -> BoneLocalModelDescriptor {
        guard let model = catalog?.model(id: id) else { throw DemoLocalModelServiceError.unknownModel }
        return model
    }

    private func storedBytes(for model: BoneLocalModelDescriptor) -> Int64? {
        guard let url = try? store.modelURL(for: model),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private static func decodeCatalog(_ data: Data) throws -> BoneLocalModelCatalog {
        guard data.count <= maximumCatalogBytes else { throw DemoLocalModelServiceError.catalogTooLarge }
        let catalog = try BoneLocalModelCatalog(data: data)
        guard catalog.models.count <= maximumModels else { throw DemoLocalModelServiceError.tooManyModels }
        return catalog
    }

    private static func readBoundedCatalog(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumCatalogBytes + 1) ?? Data()
        guard data.count <= maximumCatalogBytes else { throw DemoLocalModelServiceError.catalogTooLarge }
        return data
    }

    private struct OfflineTransport: BoneLocalModelDownloadTransport {
        func start(_ request: BoneLocalModelDownloadRequest) async throws -> any BoneLocalModelDownloadOperation {
            throw BoneLocalModelDownloadError.networkUnavailable
        }
    }
}
