import SwiftUI
import BoneAgentTools

struct LabSearchView: View {
    let workspace: LabWorkspaceModel
    @Bindable private var model: LabSearchModel
    @State private var showsBrowser = false
    @FocusState private var editing: Bool

    init(workspace: LabWorkspaceModel) {
        self.workspace = workspace
        model = workspace.search
    }
    var body: some View {
        Form {
            Section {
                Picker("搜索方式", selection: $model.channel) {
                    ForEach(DemoSearchChannel.allCases) { channel in Text(channel.title).tag(channel) }
                }
                .disabled(model.isWorking || !workspace.canEdit).accessibilityIdentifier("searchChannelPicker")
                if model.channel == .browser {
                    Picker("网页引擎", selection: $model.browserEngine) {
                        ForEach(DemoBrowserSearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine)
                        }
                    }
                    .pickerStyle(.menu).frame(minHeight: 44)
                    .disabled(model.isWorking || !workspace.canEdit)
                    .accessibilityIdentifier("browserSearchEnginePicker")
                    Text("百度和必应网页搜索无需 API Key。搜索后可选取文字交给模型。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Text(model.channel.mode).font(.subheadline).foregroundStyle(.secondary)
                if !model.isChannelAvailable {
                    Text("这个通道尚未启用，请在搜索设置中打开。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                TextField("输入搜索词", text: $model.query, axis: .vertical)
                    .lineLimit(2...4).focused($editing)
                    .disabled(model.isWorking).frame(minHeight: 72)
                    .accessibilityLabel("搜索词").accessibilityIdentifier("searchQueryInput")
                Button {
                    editing = false
                    if model.isWorking { model.stop(interactions: workspace.chat.interactions) }
                    else if model.needsSetup { workspace.openConfiguration(.network) }
                    else if workspace.canEdit {
                        model.run(interactions: workspace.chat.interactions, browserSearch: workspace.chat.browserSearch.handler)
                    }
                } label: {
                    Label(model.actionTitle, systemImage: model.isWorking ? "stop.fill" : "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent)
                .disabled(model.stopRequested || (!model.isWorking && !workspace.canEdit))
                .accessibilityIdentifier("performSearch")
                if model.isWorking { ProgressView("正在搜索…") }
                if workspace.store.isUITesting {
                    Text(ProcessInfo.processInfo.arguments.contains("--baidu-public-page-ui-test")
                         ? "真实百度网页验收 · 不调用模型" : "界面测试数据 · 未联网")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                if model.channel == .browser {
                    Text("搜索词会发给\(model.browserEngine.title)，由你浏览和选取。")
                } else if model.channel == .baiduWeb {
                    Text("本次确认后在后台读取百度公开结果并返回标题、来源与摘要，遇验证停止，无需搜索 Key。选取并运行任务后才发给模型，模型用量仍按模型账户计。")
                } else {
                    Text("仅搜索词发送到搜索服务。允许本次调用后才请求，API 可能计费。")
                }
            }
            .listRowBackground(LabStyle.surface)

            if model.channel == .baiduWeb && model.isWorking {
                Section { LiveBrowserSearchView(model: workspace.chat.browserSearch) }
                    .listRowBackground(LabStyle.surface)
            }

            if let message = model.message {
                Text(message).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("searchMessage")
            }
            if let results = model.results {
                Section {
                    Text("\(model.resultChannel?.title ?? results.provider) · \(results.results.count) 条结果")
                        .font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("searchResultSummary")
                    Text("查询：\(model.resultQuery)").font(.subheadline).textSelection(.enabled)
                    ForEach(Array(results.results.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.snippet).font(.subheadline).textSelection(.enabled)
                            Text(item.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 20) { resultActions(item, index: index) }
                                VStack(alignment: .leading) { resultActions(item, index: index) }
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } header: { Text("搜索结果") }
                  footer: { Text("结果来自搜索服务。选取前可打开来源核对；不会自动读取来源网页。") }
                .listRowBackground(LabStyle.surface)
            }
            Section {
                Button("搜索设置", systemImage: "slider.horizontal.3") { editing = false; workspace.openConfiguration(.network) }
                    .frame(minHeight: 44).disabled(!workspace.canEdit).accessibilityIdentifier("searchSettingsEntry")
                Button("返回任务", systemImage: "arrow.uturn.backward") { editing = false; workspace.returnToTask() }
                    .frame(minHeight: 44).accessibilityIdentifier("searchReturnToTask")
            }
            .listRowBackground(LabStyle.surface)
        }
        .navigationTitle("搜索")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden).background(LabStyle.canvas).tint(LabStyle.accent)
        .toolbar {
            if editing {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { editing = false }
                        .accessibilityIdentifier("searchKeyboardDone")
                }
            }
        }
        .onChange(of: model.channel) { _, _ in model.channelChanged() }
        .onChange(of: model.browserEngine) { _, _ in model.channelChanged() }
        .onChange(of: model.browser?.id) { _, id in showsBrowser = id != nil }
        .navigationDestination(isPresented: $showsBrowser) {
            if let browser = model.browser {
                LabSearchBrowserView(model: browser, onSelected: model.selectBrowserText)
            }
        }
        .sheet(item: $model.selection) { pending in
            NavigationStack {
                SearchSelectionReviewView(selection: pending.value, workspace: workspace) {
                    model.confirmSelection(workspace.useSearchMaterial)
                } onCancel: { model.selection = nil }
            }
            .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder private func resultActions(_ item: BoneWebSearchResult, index: Int) -> some View {
        Button("查看来源", systemImage: "globe") { model.openResult(item) }
            .frame(minHeight: 44).accessibilityIdentifier("openSearchSource_\(index)")
            .buttonStyle(.borderless)
        Button("选取内容", systemImage: "text.badge.plus") { model.selectResult(item) }
            .frame(minHeight: 44).accessibilityIdentifier("selectSearchResult_\(index)")
            .buttonStyle(.borderless)
    }
}

private struct SearchSelectionReviewView: View {
    let selection: DemoSearchSelection
    let workspace: LabWorkspaceModel
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        Form {
            Section("来源") {
                Text(selection.provider).font(.headline)
                Text(selection.title)
                Text(selection.url).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Section("选取的内容") {
                Text(selection.text).textSelection(.enabled).accessibilityIdentifier("selectedSearchPreview")
            }
            Section {
                Button("加入任务草稿", systemImage: "text.badge.plus", action: onConfirm)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent)
                    .disabled(!workspace.canEdit).accessibilityIdentifier("confirmSearchMaterial")
                if let error = workspace.errorMessage { Text(error).font(.subheadline).foregroundStyle(.red) }
            } footer: {
                Text("会追加到现有草稿。稍后点击运行，以上文字和来源才发送给 \(workspace.store.settings.provider.title) / \(workspace.store.settings.modelID)。请确认你愿意发送这些内容。")
            }
        }
        .navigationTitle("核对搜索材料")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(LabStyle.canvas)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消", action: onCancel) }
        }
    }
}
