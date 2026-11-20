import Foundation
import Observation
import BoneAgentLocalModels

@Observable
@MainActor
final class LocalModelLabModel {
    // One owner survives navigation, so startup cleanup and downloads never
    // restart merely because SwiftUI recreates the destination.
    static let shared = LocalModelLabModel()

    private(set) var snapshot: DemoLocalModelSnapshot?
    private(set) var probes: [String: DemoLocalModelProbe] = [:]
    private(set) var verifiedDownloads: [String: Date] = [:]
    private(set) var errorMessage: String?
    private(set) var message: String?
    private(set) var managementOperation: String?
    private(set) var activeDownloadID: String?
    private(set) var isCancelling = false
    let isUITesting: Bool

    @ObservationIgnored private var service: DemoLocalModelService?
    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var managementTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?

    var isBusy: Bool { managementOperation != nil || activeDownloadID != nil || isCancelling }
    var canRefresh: Bool { managementOperation == nil && !isCancelling }

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        isUITesting = arguments.contains("--local-model-ui-test") ||
            arguments.contains("--capability-labs-ui-test") || arguments.contains("--live-chat-ui-test")
        #else
        isUITesting = false
        #endif
    }

    deinit {
        managementTask?.cancel()
        pollingTask?.cancel()
        downloadTask?.cancel()
        cancellationTask?.cancel()
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        refresh()
    }

    func refresh() {
        guard canRefresh else { return }
        managementOperation = "刷新本地状态"
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { managementTask = nil; managementOperation = nil }
            do {
                let owner: DemoLocalModelService
                if let service { owner = service }
                else {
                    owner = try await DemoLocalModelService.openDefault(isUITesting: isUITesting)
                    service = owner
                }
                snapshot = try await owner.snapshot()
                // Refresh deliberately invalidates old inspection claims; it does
                // not rehash multi-GB files on every navigation or list update.
                probes.removeAll()
                verifiedDownloads.removeAll()
                errorMessage = nil
                message = nil
            } catch { errorMessage = Self.describe(error) }
        }
    }

    func importCatalog(_ result: Result<[URL], Error>) {
        guard !isBusy, !isUITesting, let service else { return }
        switch result {
        case .failure(let error):
            if (error as NSError).code != CocoaError.userCancelled.rawValue {
                errorMessage = Self.describe(error)
            }
        case .success(let urls):
            guard let url = urls.first else { return }
            manage("导入 SDK 模型目录") {
                try await service.importCatalog(from: url)
                self.probes.removeAll()
                self.verifiedDownloads.removeAll()
                self.message = "目录已通过 SDK 格式与来源策略检查；模型尚未下载。"
            }
        }
    }

    func download(_ modelID: String, allowsCellularAccess: Bool) {
        guard !isBusy, !isUITesting, let service else { return }
        activeDownloadID = modelID
        errorMessage = nil
        message = nil
        probes[modelID] = nil
        verifiedDownloads[modelID] = nil
        downloadTask = Task { [weak self] in
            do {
                try await service.download(modelID: modelID, allowsCellularAccess: allowsCellularAccess)
                self?.verifiedDownloads[modelID] = Date()
                self?.message = "SDK 已校验文件大小与 SHA-256 并完成安装；尚未加载运行时或生成内容。"
            } catch {
                if !Task.isCancelled, error as? BoneLocalModelDownloadError != .cancelled {
                    self?.errorMessage = Self.describe(error)
                }
            }
            guard let self else { return }
            pollingTask?.cancel()
            pollingTask = nil
            // Cancel owns the drain and final Store refresh if it has started.
            guard cancellationTask == nil else { return }
            await updateSnapshot(from: service)
            downloadTask = nil
            activeDownloadID = nil
        }
        pollingTask = Task { [weak self] in
            // The SDK only exposes state(for:), so poll solely during this owned
            // operation. There is no timer or state task while idle.
            while !Task.isCancelled {
                do {
                    let snapshot = try await service.snapshot()
                    guard !Task.isCancelled else { return }
                    self?.snapshot = snapshot
                    try await Task.sleep(for: .milliseconds(350))
                } catch { return }
            }
        }
    }

    func cancelDownload() {
        guard let downloadTask, let modelID = activeDownloadID,
              let service, cancellationTask == nil else { return }
        isCancelling = true
        downloadTask.cancel()
        pollingTask?.cancel()
        pollingTask = nil
        cancellationTask = Task { [weak self] in
            await service.cancelDownload(modelID: modelID)
            // No replacement download/delete is allowed before the old task
            // drains, including synchronous SDK installation/hash work.
            await downloadTask.value
            guard let self else { return }
            await updateSnapshot(from: service)
            self.downloadTask = nil
            activeDownloadID = nil
            isCancelling = false
            cancellationTask = nil
            message = "下载任务已停止。若取消前安装已经提交，文件会保留并显示在本地库存中。"
        }
    }

    func inspect(_ modelID: String) {
        guard !isBusy, let service else { return }
        manage("校验完整文件与检查就绪状态") {
            self.probes[modelID] = try await service.inspect(modelID: modelID)
            self.message = "文件检查已完成；请查看逐项结果。运行时未注册，无法执行加载或生成测试。"
        }
    }

    func delete(_ modelID: String) {
        guard !isBusy, let service else { return }
        manage("删除 SDK 托管文件") {
            try await service.delete(modelID: modelID)
            self.probes[modelID] = nil
            self.verifiedDownloads[modelID] = nil
            self.message = "已删除 SDK 托管模型文件，目录条目仍可用于再次下载。"
        }
    }

    func entry(_ modelID: String) -> DemoLocalModelEntry? {
        snapshot?.entries.first { $0.id == modelID }
    }

    private func manage(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, let service else { return }
        managementOperation = title
        errorMessage = nil
        message = nil
        managementTask = Task { [weak self] in
            guard let self else { return }
            defer { managementTask = nil; managementOperation = nil }
            do { try await action() }
            catch { errorMessage = Self.describe(error) }
            await updateSnapshot(from: service)
        }
    }

    private func updateSnapshot(from service: DemoLocalModelService) async {
        do { snapshot = try await service.snapshot() }
        catch { errorMessage = Self.describe(error) }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? DemoLocalModelServiceError { return error.localizedDescription }
        if case BoneLocalModelDownloadError.insufficientDiskSpace(let required, let available) = error {
            return "SDK 磁盘预检未通过：需要 \(bytes(required))，可用 \(bytes(available))。"
        }
        return "\(error.localizedDescription)\n\(String(reflecting: error))"
    }

    static func bytes(_ count: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: count, countStyle: .file))（\(count.formatted()) B）"
    }

    static func diskBudget(for model: BoneLocalModelDescriptor) -> Int64? {
        let (copies, overflow1) = model.artifact.expectedByteCount.multipliedReportingOverflow(by: 2)
        let (required, overflow2) = copies.addingReportingOverflow(BoneLocalModelDownloadPolicy().diskSafetyMarginBytes)
        return overflow1 || overflow2 ? nil : required
    }
}
