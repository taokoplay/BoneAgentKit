import SwiftUI
import BoneAgentKit

struct SDKModelPickerView: View {
    let settings: DemoLiveChatSettings
    let apiKey: String
    @Binding var modelID: String
    var isUITesting = false
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var models: [BoneInferenceProviderModelList.Model] = []
    @State private var status = "正在读取模型列表…"
    @State private var isRefreshing = false
    @State private var refreshTask: Task<Void, Never>?
    private static let sdkCatalog = try? BoneInferenceProviderCatalog.bundled()

    private var filteredModels: [BoneInferenceProviderModelList.Model] {
        models.filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search)
            || $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    private var supportsDiscovery: Bool {
        guard let entry = Self.sdkCatalog?.provider(ident: settings.provider.catalogIdent) else { return false }
        return entry.catalogMode != .manual && (entry.apiPaths["models"]?.isEmpty == false || entry.discovery != nil)
    }

    private var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var supportsEndpointMode: Bool { !settings.usesFullEndpointURL || settings.provider.isCompatibleGateway }
    private var compatibleAddressIsValid: Bool {
        !settings.provider.isCompatibleGateway || DemoLiveChatSettings.connectionURL(settings.baseURL) != nil
    }
    private var canRequestWithCredentials: Bool { hasAPIKey || settings.provider.isCompatibleGateway }

    private var canRefresh: Bool {
        supportsDiscovery && supportsEndpointMode && compatibleAddressIsValid && canRequestWithCredentials && !isRefreshing
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    SDKProviderIcon(provider: settings.provider, size: 28)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(settings.provider.title).font(.headline)
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("sdkModelSource")
                    }
                    if isRefreshing { ProgressView().accessibilityLabel("正在刷新模型") }
                }
                .padding(.vertical, 4)
                if !supportsEndpointMode {
                    Label("完整接口 URL 不支持模型发现。", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !supportsDiscovery {
                    Label("此渠道需使用内置列表或手动填写模型 ID。", systemImage: "info.circle")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !canRequestWithCredentials {
                    Label("填写 Key 后可查询账号模型。", systemImage: "key")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !isRefreshing && !models.isEmpty && !modelID.isEmpty && !models.contains(where: { $0.id == modelID }) {
                    Text("当前模型 \(modelID) 未在列表中，仍可保留或返回手动填写。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(filteredModels, id: \.id) { model in
                    Button {
                        modelID = model.id
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SDKProviderIcon(provider: settings.provider)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.displayName).font(.headline).foregroundStyle(.primary)
                                if model.displayName != model.id {
                                    Text(model.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                                Text(sourceLabel(model)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            if model.id == modelID {
                                Image(systemName: "checkmark").foregroundStyle(Color("AccentColor"))
                                    .accessibilityLabel("已选择")
                            }
                        }
                        .frame(minHeight: 52)
                        .contentShape(.rect)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(model.id == modelID ? "已选择" : "")
                    .accessibilityIdentifier("sdkModel_\(model.id)")
                }
            } header: { Text("可选模型 · \(filteredModels.count)") }
              footer: { Text("图标代表当前服务商；模型权限和工具能力以实际请求为准。") }
            if filteredModels.isEmpty && !isRefreshing {
                if !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else {
                    ContentUnavailableView {
                        Label(settings.provider.usesAccountModelList ? "暂无可选模型" : "暂无内置模型",
                              systemImage: "square.stack")
                    } actions: {
                        Button("手动填写 ID") { dismiss() }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型名称或 ID")
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await refreshModels() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新上游", systemImage: "arrow.clockwise", action: refresh)
                    .disabled(!canRefresh)
                    .accessibilityIdentifier("refreshSDKModels")
            }
        }
        .onAppear(perform: loadLocal)
        .onDisappear { refreshTask?.cancel() }
    }

    private func loadLocal() {
        do {
            let list = try DemoChatCatalog().localModels(for: settings)
            models = DemoChatCatalog.chatModels(in: list)
            if settings.provider.usesAccountModelList {
                if !compatibleAddressIsValid {
                    status = "请先填写有效的 HTTPS 接口地址"
                } else if !supportsEndpointMode || !supportsDiscovery {
                    status = "当前接口无法查询模型"
                } else if !canRequestWithCredentials {
                    status = "未填写 API Key"
                } else {
                    status = "正在通过 SDK 请求上游模型…"
                    refresh()
                }
            } else {
                status = "SDK 内置目录 · \(models.count) 个模型"
            }
        } catch { status = "SDK 目录暂不可用，可返回手动配置。" }
    }

    private func refresh() {
        guard canRefresh, refreshTask == nil else { return }
        refreshTask = Task {
            await refreshModels()
            refreshTask = nil
        }
    }

    private func refreshModels() async {
        guard canRefresh else { return }
        isRefreshing = true
        status = "正在通过 SDK 请求上游模型…"
        defer { isRefreshing = false }
        do {
            let catalog = try makeCatalog()
            let list = try await catalog.modelList(for: settings, apiKey: apiKey)
            try Task.checkCancellation()
            let fetchedModels = DemoChatCatalog.chatModels(in: list)
            if !settings.provider.isCompatibleGateway || list.discoveryOutcome == .succeeded {
                models = fetchedModels
            }
            switch list.discoveryOutcome {
            case .succeeded:
                if isUITesting {
                    status = "上游已更新（UI 测试替身）"
                } else if settings.provider.usesAccountModelList {
                    status = "账号模型 · \(models.count) 个模型"
                } else {
                    status = "上游已更新 · 已合并 SDK 内置目录"
                }
            case .notRequested:
                status = "当前地址无法推导模型列表"
            case .transportFailure(let failure):
                switch failure {
                case .invalidCredential, .httpStatus(401), .httpStatus(403):
                    status = "鉴权失败" + fallbackStatus
                default: status = "上游请求失败" + fallbackStatus
                }
            case .failed: status = "上游请求失败" + fallbackStatus
            }
        } catch is CancellationError {
            // Leaving the picker is not a failed discovery result.
        } catch let error as DemoChatConfigurationError {
            status = error.message
        } catch { status = "无法更新模型 · 保留当前列表" }
    }

    private var fallbackStatus: String {
        guard !models.isEmpty else { return "" }
        return settings.provider.isCompatibleGateway ? " · 保留当前列表" : " · 已回退 SDK 内置目录"
    }

    private func sourceLabel(_ model: BoneInferenceProviderModelList.Model) -> String {
        let origin = model.origins.contains(.catalog)
            ? (model.origins.contains(.discovery) ? "SDK 内置 · 上游可见" : "SDK 内置") : "上游模型"
        return model.capabilities.isEmpty ? origin + " · 能力未核验" : origin
    }

    private func makeCatalog() throws -> DemoChatCatalog {
        if isUITesting {
            let response: String
            if settings.provider.isCompatibleGateway {
                response = #"{"data":[{"id":"ui-gateway-model"}]}"#
            } else if settings.provider.usesAccountModelList {
                response = #"{"data":[{"id":"glm-5.3","display_name":"GLM-5.3","name":"GLM-5.3"},{"id":"glm-5.3-flash","display_name":"GLM-5.3-Flash","name":"GLM-5.3-Flash"}]}"#
            } else {
                response = #"{"data":[{"id":"ui-discovered-model"}]}"#
            }
            let discoveryData = Data(response.utf8)
            let transport = BoneInferenceURLSessionTransport(loader: { _ in
                return (discoveryData, .init(statusCode: 200, headers: ["content-type": "application/json"]))
            })
            return try DemoChatCatalog(catalog: .bundled(), transport: transport)
        }
        return try DemoChatCatalog()
    }
}
