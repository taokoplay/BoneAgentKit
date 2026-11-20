import SwiftUI

struct ToolNetworkSettingsView: View {
    let store: LiveChatSettingsStore
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var config: DemoSearchConfiguration
    @State private var initialConfig: DemoSearchConfiguration
    @State private var hosts: String
    @State private var initialHosts: String
    @State private var searchKey = ""
    @State private var initialKey = ""
    @State private var hasLoadedKey = false
    @State private var deepSeekKey = ""
    @State private var initialDeepSeekKey = ""
    @State private var hasLoadedDeepSeekKey = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @FocusState private var editing: Bool

    init(store: LiveChatSettingsStore, onSaved: @escaping () -> Void) {
        self.store = store; self.onSaved = onSaved
        _config = State(initialValue: store.settings.search)
        _initialConfig = State(initialValue: store.settings.search)
        _hosts = State(initialValue: store.settings.webAllowedHosts)
        _initialHosts = State(initialValue: store.settings.webAllowedHosts)
    }
    private var hasChanges: Bool {
        config != initialConfig || hosts != initialHosts || searchKey != initialKey || deepSeekKey != initialDeepSeekKey
    }
    private var hasLoadedCredentials: Bool { hasLoadedKey && hasLoadedDeepSeekKey }
    private var isAutomaticSelectionEnabled: Bool {
        config.automaticChannel.supportsAutomaticSearch && isChannelEnabled(config.automaticChannel)
    }
    private func isChannelEnabled(_ channel: DemoSearchChannel) -> Bool {
        switch channel {
        case .browser: config.browserEnabled
        case .baiduWeb: config.baiduWebEnabled
        case .brave: config.braveEnabled
        case .deepSeek: config.deepSeekEnabled
        }
    }

    var body: some View {
        Form {
            searchSection
            browserSection
            baiduWebSection
            braveSection
            deepSeekSection
            privacySection
            webReadingSection
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).accessibilityIdentifier("networkSettingsError")
                }
                .listRowBackground(LabStyle.surface)
            }
        }
        .navigationTitle("搜索设置")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden).background(LabStyle.canvas)
        .tint(LabStyle.accent)
        .interactiveDismissDisabled(hasChanges)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    editing = false
                    if hasChanges { confirmsDiscard = true } else { dismiss() }
                }
                .frame(minWidth: 44, minHeight: 44)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).bold()
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!hasLoadedCredentials)
                    .accessibilityIdentifier("saveNetworkSettings")
            }
            if editing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { editing = false }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("dismissToolSettingsKeyboard")
                }
            }
        }
        .alert("放弃未保存的搜索设置？", isPresented: $confirmsDiscard) {
            Button("放弃更改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .onAppear(perform: loadKeys)
    }

    private var searchSection: some View {
        Section {
            Toggle("启用搜索", isOn: $config.isEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("searchEnabledToggle")
            Picker("默认方式", selection: $config.preferredChannel) {
                ForEach(DemoSearchChannel.allCases) { channel in
                    Text(isChannelEnabled(channel) ? channel.title : "\(channel.title)（未开启）")
                        .tag(channel)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("defaultSearchChannel")
            Picker("模型自动搜索", selection: $config.automaticChannel) {
                ForEach(DemoSearchChannel.allCases.filter { $0.supportsAutomaticSearch }) { channel in
                    Text(isChannelEnabled(channel) ? channel.title : "\(channel.title)（未开启）")
                        .tag(channel)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("automaticSearchChannel")
        } header: {
            Text("搜索")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if !config.isEnabled {
                    Text("搜索已关闭，保存后仍保留各方式的设置和 Key。")
                }
                if !isChannelEnabled(config.preferredChannel) {
                    Text(config.isEnabled
                         ? "默认方式「\(config.preferredChannel.title)」未开启，请启用它或选择已开启的方式后保存。"
                         : "默认方式「\(config.preferredChannel.title)」未开启，重新启用搜索前请调整。")
                }
                Text("模型自动搜索使用所选网页问答或 API 通道，与搜索页默认方式分开；每个任务首次联网时确认一次。")
                if config.baiduWebEnabled || config.braveEnabled || config.deepSeekEnabled {
                    if !isAutomaticSelectionEnabled {
                        Text(config.isEnabled
                             ? "模型自动搜索方式「\(config.automaticChannel.title)」未开启，请启用它或选择已开启的通道后保存。"
                             : "模型自动搜索方式「\(config.automaticChannel.title)」未开启，重新启用搜索前请调整。")
                    }
                } else {
                    Text("自动搜索通道均未开启，可启用百度网页问答或搜索 API。")
                }
            }
        }
        .listRowBackground(LabStyle.surface)
    }

    private var browserSection: some View {
        Section {
            Toggle("启用网页搜索", isOn: $config.browserEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("browserSearchToggle")
            Picker("默认引擎", selection: $config.browserEngine) {
                ForEach(DemoBrowserSearchEngine.allCases) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("browserEnginePicker")
        } header: {
            Text("网页搜索")
        } footer: {
            Text("手动浏览，不自动读取搜索结果。选取内容后可加入任务。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private var baiduWebSection: some View {
        Section {
            Toggle("启用免费百度网页问答", isOn: $config.baiduWebEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("baiduWebSearchToggle")
                .onChange(of: config.baiduWebEnabled) { _, enabled in
                    if enabled && !config.braveEnabled && !config.deepSeekEnabled {
                        config.automaticChannel = .baiduWeb
                    }
                }
        } header: {
            Text("百度网页问答")
        } footer: {
            Text("本次任务确认后，在后台读取有限的百度公开搜索结果，并以标题、来源、摘要和读取时间交给当前模型；遇验证即停止，不自动打开网页。搜索本身无需 API Key，模型用量仍按模型账户计。搜索页先展示结构化结果，选取并运行任务后才发给模型。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private var braveSection: some View {
        Section {
            Toggle("启用 Brave Search", isOn: $config.braveEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("braveSearchChannelToggle")
            SecureField("Brave Search API Key", text: $searchKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($editing).privacySensitive().frame(minHeight: 44)
                .accessibilityLabel("Brave Search API Key")
                .accessibilityIdentifier("searchAPIKeyField")
                .disabled(!hasLoadedKey)
            if !searchKey.isEmpty {
                Button("清除 Brave 搜索 Key", role: .destructive) { searchKey = "" }
                    .frame(minHeight: 44)
            }
            if !hasLoadedKey {
                Button("重新读取 Brave 搜索凭据", action: loadKeys).frame(minHeight: 44)
            } else if config.braveEnabled && searchKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("待配置：搜索 Key。可以先保存，填写 Key 后才能使用 Brave API。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Link("前往 Brave 官网获取 Key", destination: URL(string: "https://brave.com/search/api/")!)
                .frame(minHeight: 44)
        } header: {
            Text("Brave Search API")
        } footer: {
            Text("API 自动搜索，任务内首次联网时确认一次，可能计费。Key 仅保存在本机；清除后保存才生效。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private var deepSeekSection: some View {
        Section {
            Toggle("启用 DeepSeek Search", isOn: $config.deepSeekEnabled)
                .frame(minHeight: 44)
                .accessibilityIdentifier("deepSeekSearchToggle")
            SecureField("DeepSeek Search API Key", text: $deepSeekKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($editing).privacySensitive().frame(minHeight: 44)
                .accessibilityLabel("DeepSeek Search API Key")
                .accessibilityIdentifier("deepSeekSearchAPIKeyField")
                .disabled(!hasLoadedDeepSeekKey)
            if !deepSeekKey.isEmpty {
                Button("清除 DeepSeek 搜索 Key", role: .destructive) { deepSeekKey = "" }
                    .frame(minHeight: 44)
            }
            if !hasLoadedDeepSeekKey {
                Button("重新读取 DeepSeek 搜索凭据", action: loadKeys).frame(minHeight: 44)
            } else if config.deepSeekEnabled && deepSeekKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("待配置：搜索 Key。可以先保存，填写 Key 后才能使用 DeepSeek Search API。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Link("前往 DeepSeek 官网获取 Key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                .frame(minHeight: 44)
        } header: {
            Text("DeepSeek Search")
        } footer: {
            Text("官方搜索 API，可供任意聊天模型使用，按请求计费；与模型连接的 Key 分开保存。每个任务首次联网时确认一次；清除后保存才生效。")
        }
        .listRowBackground(LabStyle.surface)
    }

    private var privacySection: some View {
        Section {
            DisclosureGroup("浏览器隐私（可选）") {
                Toggle("保留网页登录状态", isOn: $config.keepsBrowserSession)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("keepsSearchBrowserSession")
                Text("仅用于手动网页浏览，默认临时会话。开启后保留网页登录状态，关闭后新页面不沿用。百度网页问答始终使用临时无登录会话。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(LabStyle.surface)
    }

    private var webReadingSection: some View {
        Section {
            DisclosureGroup("网页读取（可选）") {
                TextField("例如：developer.apple.com\ndocs.swift.org", text: $hosts, axis: .vertical)
                    .lineLimit(3...8).keyboardType(.URL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($editing).frame(minHeight: 72)
                    .accessibilityLabel("允许读取的网页域名")
                    .accessibilityIdentifier("webAllowedHostsField")
                Text("每行填一个公开域名，不含协议、路径或通配符；可留空，访问前仍需你确认。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 44)
        }
        .listRowBackground(LabStyle.surface)
    }

    private func loadKeys() {
        guard !hasLoadedCredentials else { return }
        if !hasLoadedKey {
            do {
                let loadedKey = try store.searchKey()
                searchKey = loadedKey; initialKey = loadedKey
                hasLoadedKey = true
            } catch { hasLoadedKey = false }
        }
        if !hasLoadedDeepSeekKey {
            do {
                let loadedKey = try store.deepSeekSearchKey()
                deepSeekKey = loadedKey; initialDeepSeekKey = loadedKey
                hasLoadedDeepSeekKey = true
            } catch { hasLoadedDeepSeekKey = false }
        }
        errorMessage = hasLoadedCredentials ? nil : "无法读取全部搜索凭据，请解锁设备后重试。读取成功前无法保存。"
    }
    private func save() {
        guard hasLoadedCredentials else { return }
        editing = false
        do {
            try store.saveSearch(config, searchAPIKey: searchKey, deepSeekAPIKey: deepSeekKey, allowedHosts: hosts)
            initialConfig = config; initialHosts = hosts; initialKey = searchKey; initialDeepSeekKey = deepSeekKey
            onSaved(); dismiss()
        } catch let error as DemoSearchError { errorMessage = error.message }
        catch let error as DemoChatConfigurationError { errorMessage = error.message }
        catch let error as LiveChatKeychainError { errorMessage = error.message }
        catch { errorMessage = "搜索设置未保存，请检查搜索方式、公开域名和搜索 Key。" }
    }
}
