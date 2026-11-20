import SwiftUI

struct LiveModelSettingsView: View {
    private enum Field: Hashable { case address, key, model }
    let store: LiveChatSettingsStore
    let onSaved: () -> Void
    let onManageTools: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: DemoLiveChatSettings
    @State private var apiKey = ""
    @State private var initialKey = ""
    @State private var loadedKeyAccount = ""
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false
    @State private var confirmsDiscard = false
    @State private var showsError = false
    @State private var hasLoadedInitialKey = false
    @State private var confirmsToolNavigation = false
    @State private var opensToolsAfterSave = false
    @State private var showsProviders = false
    @State private var showsModels = false
    @State private var showsAdvanced = false
    @State private var showsResponseOptions = false
    @State private var showsSessionOptions = false
    @FocusState private var focusedField: Field?

    init(store: LiveChatSettingsStore, onSaved: @escaping () -> Void, onManageTools: @escaping () -> Void = {}) {
        self.store = store
        self.onSaved = onSaved
        self.onManageTools = onManageTools
        _draft = State(initialValue: store.settings)
    }

    private var hasChanges: Bool { draft != store.settings || apiKey != initialKey }

    var body: some View {
        Form {
            connectionSection
            advancedSection
            responseOptionsSection
            sessionOptionsSection
            Section {
                Button {
                    focusedField = nil
                    if hasChanges { confirmsToolNavigation = true }
                    else { dismiss(); onManageTools() }
                } label: {
                    Label("选择工具", systemImage: "checklist").frame(minHeight: 44)
                }
                .accessibilityIdentifier("builtInToolsSettings")
            }
        }
        .navigationTitle("模型设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .scrollDismissesKeyboard(.interactively)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .interactiveDismissDisabled(hasChanges)
        .navigationDestination(isPresented: $showsProviders) {
            SDKProviderPickerView(selection: $draft.provider)
        }
        .navigationDestination(isPresented: $showsModels) {
            SDKModelPickerView(settings: draft, apiKey: apiKey, modelID: $draft.modelID,
                               isUITesting: store.isUITesting)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    focusedField = nil
                    if hasChanges { confirmsDiscard = true } else { dismiss() }
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("cancelModelSettings")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save)
                    .bold()
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("saveModelSettings")
            }
            if focusedField != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { focusedField = nil }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("dismissSettingsKeyboard")
                }
            }
        }
        .alert("放弃未保存的更改？", isPresented: $confirmsDiscard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("前往实验室前保存更改？", isPresented: $confirmsToolNavigation) {
            Button("保存并前往实验室") { opensToolsAfterSave = true; save() }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("放弃更改并前往", role: .destructive) { dismiss(); onManageTools() }
            Button("继续编辑", role: .cancel) {}
        }
        .confirmationDialog("删除此接口保存在手机上的 Key？", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("删除 Key", role: .destructive, action: deleteKey)
            Button("取消", role: .cancel) {}
        }
        .alert("操作未完成", isPresented: $showsError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "请检查设置后重试。")
        }
        .onAppear {
            guard !hasLoadedInitialKey else { return }
            hasLoadedInitialKey = true
            loadKey()
        }
        .onChange(of: draft.provider) { previous, provider in
            guard previous.catalogIdent != provider.catalogIdent
                    || previous.isLegacyOpenAIConnection != provider.isLegacyOpenAIConnection else { return }
            draft.selectProvider(provider)
        }
        .onChange(of: draft.credentialAccount) { _, _ in loadKey() }
        .onChange(of: draft.visionBindingFingerprint) { _, _ in draft.resetVisionBinding() }
    }

    private var connectionSection: some View {
        Section {
            Button {
                focusedField = nil
                showsProviders = true
            } label: {
                HStack(spacing: LabStyle.itemSpacing) {
                    SDKProviderIcon(provider: draft.provider, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("服务商").font(.footnote).foregroundStyle(.secondary)
                        Text(draft.provider.title).font(.headline)
                    }
                    Spacer(minLength: 4)
                    chevron
                }
                .frame(minHeight: 52)
                .contentShape(.rect)
                .foregroundStyle(.primary)
            }
            .accessibilityIdentifier("providerPicker")
            VStack(alignment: .leading, spacing: 4) {
                Text("模型").font(.subheadline.bold())
                TextField("选择或填写模型 ID", text: $draft.modelID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .model)
                    .frame(minHeight: 44)
                    .accessibilityLabel("模型 ID")
                    .accessibilityIdentifier("modelIDField")
                Button(draft.provider.usesAccountModelList ? "从账号模型列表选择" : "从 SDK 目录选择", systemImage: "list.bullet") {
                    focusedField = nil
                    showsModels = true
                }
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("chooseSDKModel")
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key").font(.subheadline.bold())
                SecureField("填写此服务商的 Key", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .key)
                    .frame(minHeight: 44)
                    .privacySensitive()
                    .accessibilityLabel("API Key")
                    .accessibilityIdentifier("apiKeyField")
            }
            .padding(.vertical, 4)
        } header: { Text("必需配置") }
          footer: {
            Text("对话和所有真实测试共用此模型。")
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("接口地址").font(.subheadline.bold())
                    TextField("Base URL", text: $draft.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .address)
                        .frame(minHeight: 44)
                        .accessibilityLabel("接口地址")
                        .accessibilityIdentifier("baseURLField")
                }
                .padding(.vertical, 4)
                if draft.provider.supportsFullEndpointURL {
                    Toggle("使用完整接口 URL", isOn: $draft.usesFullEndpointURL)
                        .frame(minHeight: 44)
                }
                if draft.provider.isLegacyOpenAIConnection {
                    Text("此连接保留旧版 OpenAI 兼容配置。重新选择 DeepSeek 才会应用 SDK 当前默认值。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Label("Key 仅保存在本机", systemImage: "lock.shield")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("删除此接口的 Key", role: .destructive) {
                    focusedField = nil
                    confirmsDeletion = true
                }
                .frame(minHeight: 44)
                .disabled(apiKey.isEmpty)
            } label: {
                Label("高级连接设置", systemImage: "slider.horizontal.3")
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("advancedSettings")
            }
        } footer: {
            if showsAdvanced {
                Text("可修改自定义接口或完整 URL。Key 按协议和接口分别保存，更换地址后需填写对应 Key。")
            }
        }
    }

    private var responseOptionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsResponseOptions) {
                LiveModelBudgetFields(draft: $draft)
            } label: {
                Label("回复与上下文（可选）", systemImage: "text.bubble")
                    .frame(minHeight: 44)
            }
        } footer: {
            if showsResponseOptions {
                Text("流式不可用时可手动关闭，不会自动重发；每轮最多 6 次推理。")
            }
        }
    }

    private var sessionOptionsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showsSessionOptions) {
                NavigationLink {
                    SDKVisionSettingsView(draft: $draft)
                } label: {
                    LabeledContent("图片理解", value: draft.visionPolicy == .disabled ? "未配置" : "已配置规则")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("visionSettings")
                Toggle("本机保存已完成会话", isOn: $draft.preservesConversation)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("persistConversationToggle")
            } label: {
                Label("会话与图片（可选）", systemImage: "photo.on.rectangle")
                    .frame(minHeight: 44)
            }
        } footer: {
            if showsSessionOptions {
                Text("图片在本机预处理，发送时按模型校验容量和读取权限。会话保存包含正文、工具历史和导入材料，存于 App 私有空间并排除系统备份；只恢复已完成历史，不会重发中断请求，统计从本次启动开始。")
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
    }

    private func loadKey() {
        apiKey = ""
        initialKey = ""
        errorMessage = nil
        loadedKeyAccount = draft.credentialAccount
        do {
            apiKey = try store.key(for: draft)
            initialKey = apiKey
        } catch let error as LiveChatKeychainError { errorMessage = error.message }
        catch { errorMessage = "无法读取此接口的 Key，请重新填写。" }
    }

    private func save() {
        focusedField = nil
        if !hasChanges {
            dismiss()
            if opensToolsAfterSave { onManageTools() }
            return
        }
        do {
            guard loadedKeyAccount == draft.credentialAccount else {
                presentError("接口刚发生变化，请重新填写此接口的 Key。")
                return
            }
            draft.bindVisionToCurrentModel()
            try store.save(draft, apiKey: apiKey)
            initialKey = apiKey
            draft = store.settings
            onSaved()
            dismiss()
            if opensToolsAfterSave { onManageTools() }
        } catch let error as DemoChatConfigurationError { presentError(error.message) }
        catch let error as LiveChatKeychainError { presentError(error.message) }
        catch DemoTextResourceStoreError.largeResourceCannotBeSaved {
            presentError("文件正在处理，或当前会话含有大附件。此次未开启保存，也未改动旧存档。请等待文件处理完成；如仍有大附件，先移除附件或保持保存关闭。")
        }
        catch { presentError("设置未保存，请检查后重试。") }
    }

    private func deleteKey() {
        do {
            try store.deleteKey(for: draft)
            apiKey = ""
            initialKey = ""
            onSaved()
        } catch let error as LiveChatKeychainError { presentError(error.message) }
        catch { presentError("未能删除 Key，请重试。") }
    }

    private func presentError(_ message: String) {
        opensToolsAfterSave = false
        errorMessage = message
        showsError = true
    }
}
