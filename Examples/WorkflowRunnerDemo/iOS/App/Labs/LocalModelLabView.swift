import SwiftUI
import UniformTypeIdentifiers
import BoneAgentLocalModels

struct LocalModelLabView: View {
    @State private var model = LocalModelLabModel.shared
    @State private var showsImporter = false

    var body: some View {
        Form {
            Section {
                Label("本机模型资产管理", systemImage: "internaldrive")
                    .font(.headline)
                Text("查看目录与本地文件，按需下载、校验或删除。只有点击下载才会访问模型来源。")
                    .foregroundStyle(.secondary)
                if model.isUITesting {
                    Label("离线 UI 测试 · 空目录 · 禁用网络", systemImage: "network.slash")
                        .accessibilityIdentifier("localModelsOfflineMode")
                }
            }
            .listRowBackground(LabStyle.surface)

            LocalModelRuntimeSection()
            LocalModelMessages(model: model)

            if let snapshot = model.snapshot {
                inventorySection(snapshot)
                catalogSection(snapshot)
                LocalModelEnvironmentSection(environment: snapshot.environment)
                Section("存储位置") {
                    Text(snapshot.storageURL.path)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Text("文件保存在本 App 的 Application Support / AgentLabLocalModels 中，由 SDK Store 管理并排除系统备份。目录 JSON 随 App 保留。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(LabStyle.surface)
            }
        }
        .navigationTitle("本地模型")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(!model.canRefresh)
                    .accessibilityIdentifier("localModelsRefresh")
            }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) {
            model.importCatalog($0)
        }
        .task { model.startIfNeeded() }
        .accessibilityIdentifier("localModelsLab")
    }

    private func inventorySection(_ snapshot: DemoLocalModelSnapshot) -> some View {
        Section {
            let stored = snapshot.entries.filter(\.hasStoredAsset)
            if stored.isEmpty {
                Text("没有已识别的 SDK 托管模型文件。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("localModelsEmptyInventory")
            }
            ForEach(stored) { entry in modelLink(entry) }
        } header: {
            Text("本地库存")
        } footer: {
            Text("按保留目录中的模型 ID 与文件名检查实际存储；普通刷新只核对文件大小，完整 SHA-256 校验需在详情中启动。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private func catalogSection(_ snapshot: DemoLocalModelSnapshot) -> some View {
        Section {
            Text("此 SDK 未附带可下载模型的内置清单。导入可信来源提供的 SDK 目录 JSON 后可查看模型与下载来源。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("localModelsNoBundledCatalog")
            if let issue = snapshot.catalogIssue {
                Text(issue).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("localModelsCatalogError")
            }
            if let version = snapshot.catalogVersion {
                LabeledContent("已导入目录版本", value: version.formatted())
                LabeledContent("目录声明 runtimeVersion", value: snapshot.catalogRuntimeVersion?.formatted() ?? "未知")
            }
            if snapshot.entries.isEmpty {
                Text("目录为空，尚无可下载条目。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("localModelsEmptyCatalog")
            }
            ForEach(snapshot.entries) { entry in modelLink(entry) }
            Button("导入模型目录 JSON", systemImage: "square.and.arrow.down") { showsImporter = true }
                .frame(minHeight: 44)
                .disabled(model.isBusy || model.isUITesting)
                .accessibilityIdentifier("localModelsImportCatalog")
        } header: {
            Text("SDK 模型目录")
        } footer: {
            Text("最多 1 MiB、64 个模型。使用 BoneLocalModelCatalog 校验结构、HTTPS 来源及允许的主机；这不验证目录发布者身份。现有本地文件的元数据必须保留。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private func modelLink(_ entry: DemoLocalModelEntry) -> some View {
        NavigationLink {
            LocalModelDetailView(model: model, modelID: entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.model.displayName).foregroundStyle(.primary)
                Text("\(entry.model.family) · \(entry.model.quantization) · \(LocalModelLabModel.bytes(entry.model.artifact.expectedByteCount))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(LocalModelPresentation.installation(entry.installation))
                    .font(.caption)
                    .foregroundStyle(entry.isInstalled ? LabStyle.accent : .secondary)
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("localModelEntry-\(entry.id)")
    }
}

private struct LocalModelDetailView: View {
    let model: LocalModelLabModel
    let modelID: String
    @State private var allowsCellularAccess = false
    @State private var confirmsDelete = false

    var body: some View {
        Form {
            if let entry = model.entry(modelID), let snapshot = model.snapshot {
                facts(entry.model)
                status(entry)
                operations(entry, environment: snapshot.environment)
                preflight(entry.model, environment: snapshot.environment)
                LocalModelRuntimeSection()
                probeSection(entry)
                sources(entry.model)
                LocalModelMessages(model: model)
            } else {
                Text("模型已不在当前目录中，请返回并刷新目录。")
                    .textSelection(.enabled)
            }
        }
        .navigationTitle(model.entry(modelID)?.model.displayName ?? "模型详情")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新", systemImage: "arrow.clockwise") { model.refresh() }
                    .disabled(!model.canRefresh)
                    .accessibilityIdentifier("localModelRefresh")
            }
        }
        .confirmationDialog("删除 SDK 托管模型文件？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("删除本地模型文件", role: .destructive) { model.delete(modelID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除 \(model.entry(modelID)?.model.displayName ?? modelID) 在 AgentLabLocalModels 中的 SDK 托管文件。再次使用需要重新下载。")
        }
        .onDisappear {
            if model.activeDownloadID == modelID { model.cancelDownload() }
        }
        .accessibilityIdentifier("localModelDetail")
    }

    private func facts(_ descriptor: BoneLocalModelDescriptor) -> some View {
        Section("目录元数据") {
            LabeledContent("模型 ID", value: descriptor.id).textSelection(.enabled)
            LabeledContent("系列", value: descriptor.family)
            LabeledContent("格式 / 量化", value: "\(descriptor.format.rawValue.uppercased()) / \(descriptor.quantization)")
            LabeledContent("参数量", value: descriptor.parameterCount.formatted())
            LabeledContent("模型文件", value: descriptor.artifact.fileName).textSelection(.enabled)
            LabeledContent("精确下载大小", value: LocalModelLabModel.bytes(descriptor.artifact.expectedByteCount))
            LabeledContent("建议上下文", value: "\(descriptor.recommendedContextTokens.formatted()) tokens")
            LabeledContent("目录上下文上限", value: "\(descriptor.contextLimits.contextWindowTokens.formatted()) tokens")
            LabeledContent("最低运行时版本", value: descriptor.minimumRuntimeVersion.formatted())
            VStack(alignment: .leading, spacing: 6) {
                Text("目录 SHA-256").font(.subheadline)
                Text(descriptor.artifact.sha256)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .listRowBackground(LabStyle.surface)
    }

    private func status(_ entry: DemoLocalModelEntry) -> some View {
        Section("实际文件与传输快照") {
            LabeledContent("本地文件", value: LocalModelPresentation.installation(entry.installation))
                .textSelection(.enabled)
                .accessibilityIdentifier("localModelInstallationState")
            if let bytes = entry.storedByteCount {
                LabeledContent("实际文件大小", value: LocalModelLabModel.bytes(bytes))
            }
            if case .installed(let url) = entry.installation {
                Text(url.path).font(.caption.monospaced()).textSelection(.enabled)
            }
            LabeledContent("本次会话传输状态", value: LocalModelPresentation.download(entry.download))
                .textSelection(.enabled)
                .accessibilityIdentifier("localModelDownloadState")
            if case .downloading(_, let progress) = entry.download {
                ProgressView(value: progress.fractionCompleted)
                    .accessibilityIdentifier("localModelDownloadProgress")
                Text("\(LocalModelLabModel.bytes(progress.downloadedBytes)) / \(LocalModelLabModel.bytes(progress.expectedBytes))")
                    .font(.caption)
                    .monospacedDigit()
                if progress.downloadedBytes == progress.expectedBytes {
                    Text("已收齐字节，等待 SDK 校验与安装结果。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.isInstalled, let checkedAt = model.verifiedDownloads[modelID] {
                Text("SDK 安装时大小与 SHA-256 校验通过：\(checkedAt.formatted(date: .omitted, time: .standard))。格式签名可通过下方文件检查确认。")
                    .font(.footnote)
            } else if model.probes[modelID] == nil {
                Text("完整性尚未在本次检查中确认。文件存在或大小匹配不会单独证明可推理。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(LabStyle.surface)
    }

    private func operations(_ entry: DemoLocalModelEntry, environment: BoneLocalRuntimeEnvironment) -> some View {
        Section {
            if model.activeDownloadID == modelID {
                Button(model.isCancelling ? "正在取消并等待文件操作结束…" : "取消下载", systemImage: "xmark.circle") {
                    model.cancelDownload()
                }
                .frame(minHeight: 44)
                .disabled(model.isCancelling)
                .accessibilityIdentifier("localModelCancelDownload")
            } else if !entry.hasStoredAsset {
                Toggle("允许蜂窝网络", isOn: $allowsCellularAccess)
                    .disabled(model.isBusy)
                Button {
                    model.download(modelID, allowsCellularAccess: allowsCellularAccess)
                } label: {
                    Label("下载并校验模型文件", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(LabStyle.onAccent)
                .disabled(model.isBusy || model.isUITesting || !hasDiskBudget(entry.model, environment))
                .accessibilityIdentifier("localModelDownload")
            }
            if entry.hasStoredAsset {
                Button("校验文件并检查就绪状态", systemImage: "checkmark.shield") { model.inspect(modelID) }
                    .frame(minHeight: 44)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("localModelInspect")
                Button("删除本地文件", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .frame(minHeight: 44)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("localModelDelete")
            }
        } header: {
            Text("管理操作")
        } footer: {
            Text("每次只运行一个下载。下载由 SDK URLSession 执行，大小与 SHA-256 通过后才安装。离开此页会取消活动下载；取消需等待文件操作结束，已提交的安装会保留。完整文件校验可能耗时。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private func preflight(_ descriptor: BoneLocalModelDescriptor, environment: BoneLocalRuntimeEnvironment) -> some View {
        Section("下载与设备预检") {
            LabeledContent("可用磁盘", value: LocalModelLabModel.bytes(environment.availableDiskBytes))
            LabeledContent("SDK 下载磁盘预算", value: LocalModelLabModel.diskBudget(for: descriptor).map(LocalModelLabModel.bytes) ?? "大小溢出，无法下载")
            LabeledContent("磁盘预检", value: hasDiskBudget(descriptor, environment) ? "满足上次快照预算" : "空间不足，请清理后刷新")
            LabeledContent("物理内存", value: LocalModelLabModel.bytes(Int64(clamping: environment.physicalMemoryBytes)))
            LabeledContent("目录最低内存", value: LocalModelLabModel.bytes(Int64(clamping: descriptor.minimumMemoryBytes)))
            LabeledContent("内存门槛", value: environment.physicalMemoryBytes >= descriptor.minimumMemoryBytes ? "满足目录要求" : "低于目录要求")
            LabeledContent("平台", value: environment.isSimulator ? "iOS 模拟器" : "iOS 设备")
            Text("磁盘预算为两份模型文件与 SDK 默认安全余量；开始下载前会重新读取环境。物理内存不是 App 可用内存。当前没有运行时的系统、架构或 GPU 支持信息，平台兼容性尚未验证。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(LabStyle.surface)
    }

    private func probeSection(_ entry: DemoLocalModelEntry) -> some View {
        Section {
            if let probe = model.probes[modelID] {
                LabeledContent("检查时间", value: probe.checkedAt.formatted(date: .abbreviated, time: .standard))
                LabeledContent("检查范围", value: "metadata · 文件及静态环境")
                LabeledContent("综合结果", value: String(describing: probe.report.status))
                    .accessibilityIdentifier("localModelProbeStatus")
                ForEach(Array(probe.report.checks.enumerated()), id: \.offset) { _, check in
                    LabeledContent(LocalModelPresentation.check(check.kind), value: LocalModelPresentation.checkStatus(check.status))
                }
                LabeledContent("已验证的生成能力", value: probe.report.verifiedCapabilities.isEmpty ? "无" : "\(probe.report.verifiedCapabilities.count)")
            } else {
                Text(entry.hasStoredAsset ? "尚未执行文件检查。点击“校验文件并检查就绪状态”会读取完整文件并运行 SDK Artifact Inspector。" : "下载后可校验完整文件与 GGUF 文件头。")
                    .foregroundStyle(.secondary)
            }
            Text("检查包含安装、大小、SHA-256、GGUF 四字节签名与目录内存门槛。未运行模型加载或生成 smoke test；格式签名通过也不能证明 tokenizer、架构或量化可被运行时执行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("文件检查 / Probe")
        }
        .textSelection(.enabled)
        .listRowBackground(LabStyle.surface)
    }

    private func sources(_ descriptor: BoneLocalModelDescriptor) -> some View {
        Section("来源与许可") {
            Link("许可：\(descriptor.license.name)", destination: descriptor.license.url)
            Link("模型说明", destination: descriptor.license.modelCardURL)
            ForEach(descriptor.artifact.sources.sorted { $0.priority < $1.priority }, id: \.id) { source in
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(source.id) · 优先级 \(source.priority)").font(.subheadline)
                    Text(source.url.absoluteString).font(.caption.monospaced())
                    Text("允许的主机：\(source.allowedHosts.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
        }
        .listRowBackground(LabStyle.surface)
    }

    private func hasDiskBudget(_ descriptor: BoneLocalModelDescriptor, _ environment: BoneLocalRuntimeEnvironment) -> Bool {
        guard let required = LocalModelLabModel.diskBudget(for: descriptor) else { return false }
        return environment.availableDiskBytes >= required
    }
}

private struct LocalModelRuntimeSection: View {
    var body: some View {
        Section("本地推理就绪状态") {
            Label("未就绪 · runtimeNotRegistered", systemImage: "exclamationmark.circle")
                .accessibilityIdentifier("localModelsRuntimeNotRegistered")
            LabeledContent("运行时注册", value: "未注册可执行后端")
            LabeledContent("环境支持", value: "等待真实运行时确认")
            LabeledContent("模型加载 / 实际生成", value: "未执行")
            Text("当前示例未链接可执行的 llama Runtime 实现。资产管理可用；接入真正的 BoneLlamaRuntime 与对应二进制后，才能验证设备支持、加载模型和执行本地生成。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .listRowBackground(LabStyle.surface)
    }
}

private struct LocalModelEnvironmentSection: View {
    let environment: BoneLocalRuntimeEnvironment

    var body: some View {
        Section("SDK 环境快照") {
            LabeledContent("平台", value: environment.isSimulator ? "iOS 模拟器" : "iOS 设备")
            LabeledContent("物理内存", value: LocalModelLabModel.bytes(Int64(clamping: environment.physicalMemoryBytes)))
            LabeledContent("可用磁盘", value: LocalModelLabModel.bytes(environment.availableDiskBytes))
            LabeledContent("活动处理器", value: environment.activeProcessorCount.formatted())
            LabeledContent("低电量模式", value: environment.isLowPowerModeEnabled ? "开启" : "关闭")
            LabeledContent("温控状态", value: String(describing: environment.thermalState))
            Text("通过 BoneLocalRuntimeEnvironment 读取；点击刷新更新。环境快照不等于运行时或模型兼容性验证。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .listRowBackground(LabStyle.surface)
    }
}

private struct LocalModelMessages: View {
    let model: LocalModelLabModel

    var body: some View {
        if let operation = model.managementOperation {
            Section {
                HStack(spacing: 10) {
                    ProgressView().tint(LabStyle.accent)
                    Text(operation)
                }
            }
            .listRowBackground(LabStyle.surface)
        }
        if let error = model.errorMessage {
            Section("操作结果") {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
                    .accessibilityIdentifier("localModelsError")
            }
            .listRowBackground(LabStyle.surface)
        } else if let message = model.message {
            Section("操作结果") {
                Text(message).font(.subheadline).textSelection(.enabled)
                    .accessibilityIdentifier("localModelsMessage")
            }
            .listRowBackground(LabStyle.surface)
        }
    }
}

private enum LocalModelPresentation {
    static func installation(_ state: BoneLocalModelInstallationState) -> String {
        switch state {
        case .notInstalled: return "未下载"
        case .installed: return "已下载 · 文件大小匹配"
        case .invalid(let error): return "本地文件异常 · \(String(describing: error))"
        }
    }

    static func download(_ state: BoneLocalModelDownloadState) -> String {
        switch state {
        case .idle: return "idle · 无活动传输"
        case .preparing(let source): return "preparing · \(source)"
        case .downloading(let source, _): return "downloading · \(source)"
        case .paused(let source, _): return "paused · \(source)"
        case .verifying: return "verifying · SDK 正在校验与安装"
        case .installed: return "installed · 上次传输已安装（文件以库存为准）"
        case .cancelled: return "cancelled · 已取消"
        case .failed(let error): return "failed · \(String(describing: error))"
        }
    }

    static func check(_ kind: BoneLocalRuntimeProbeCheckKind) -> String {
        switch kind {
        case .installation: return "安装文件"
        case .artifactIntegrity: return "大小 / SHA-256"
        case .formatSignature: return "GGUF 签名"
        case .deviceMemory: return "目录物理内存门槛"
        case .adapterAvailability: return "运行时适配器"
        default: return kind.rawValue
        }
    }

    static func checkStatus(_ status: BoneLocalRuntimeProbeCheckStatus) -> String {
        switch status {
        case .passed: return "passed · 通过"
        case .temporarilyUnavailable: return "temporarilyUnavailable · 暂不可用"
        case .unsupported: return "unsupported · 未提供支持"
        case .incompatible: return "incompatible · 不兼容"
        case .corrupted: return "corrupted · 文件损坏或缺失"
        case .failed: return "failed · 失败"
        }
    }
}
