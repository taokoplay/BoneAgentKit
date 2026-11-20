import SwiftUI

struct LabSettingsView: View {
    let workspace: LabWorkspaceModel

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    LiveModelSettingsView(store: workspace.store, onSaved: workspace.configurationSaved,
                                          onManageTools: workspace.openTools)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("模型连接", systemImage: "network")
                        Text("\(workspace.store.settings.provider.title) · \(workspace.store.settings.modelID)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("sharedModelSettings")
                NavigationLink {
                    LabInstructionSettingsView(store: workspace.store, onSaved: workspace.configurationSaved)
                } label: {
                    Label("助手说明", systemImage: "text.bubble").frame(minHeight: 44)
                }
                .accessibilityIdentifier("sharedInstructionSettings")
            } header: { Text("模型与回答") }
              footer: { Text("对话和所有模型测试共用这里的设置。") }
            .listRowBackground(LabStyle.surface)

            Section("工具") {
                Button("选择工具", systemImage: "checklist", action: workspace.openTools)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("sharedToolSettings")
                NavigationLink {
                    ToolNetworkSettingsView(store: workspace.store, onSaved: workspace.configurationSaved)
                } label: {
                    Label("搜索设置", systemImage: "magnifyingglass").frame(minHeight: 44)
                }
                .accessibilityIdentifier("sharedNetworkSettings")
                Button("打开搜索", systemImage: "globe", action: workspace.openSearch)
                    .frame(minHeight: 44).accessibilityIdentifier("sharedOpenSearch")
                Text(workspace.selectedPlan.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            .listRowBackground(LabStyle.surface)
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { workspace.configuration = nil }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("closeUnifiedSettings")
            }
        }
    }
}

struct LabInstructionSettingsView: View {
    let store: LiveChatSettingsStore
    let onSaved: () -> Void
    @State private var text: String
    @State private var error: String?
    @State private var confirmsDiscard = false
    @FocusState private var editing: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: LiveChatSettingsStore, onSaved: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        _text = State(initialValue: store.settings.systemPrompt)
    }
    private var changed: Bool { text != store.settings.systemPrompt }

    var body: some View {
        Form {
            Section {
                TextField("例如：请用简短中文回答，先给结论。", text: $text, axis: .vertical)
                    .lineLimit(8...16)
                    .frame(minHeight: 180, alignment: .topLeading)
                    .focused($editing)
                    .accessibilityLabel("助手说明")
                    .accessibilityIdentifier("sharedInstructionInput")
            } header: { Text("希望助手怎样回答") }
              footer: { Text("保存后，对话和模型测试都会使用这段说明。") }
            .listRowBackground(LabStyle.surface)
            if let error { Text(error).foregroundStyle(.red) }
            if text.utf8.count > 16_384 { Text("说明过长，请缩短后保存。").foregroundStyle(.red) }
        }
        .navigationTitle("助手说明")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(changed)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") {
                    if changed { confirmsDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    editing = false
                    do { try store.saveAssistantInstructions(text); onSaved() }
                    catch let failure as DemoChatConfigurationError { error = failure.message }
                    catch { self.error = "保存未完成，请重试。" }
                }
                .disabled(text.utf8.count > 16_384)
                .accessibilityIdentifier("saveSharedInstructions")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if editing {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { editing = false }
                        .accessibilityIdentifier("instructionKeyboardDone")
                }
            }
        }
        .alert("放弃修改？", isPresented: $confirmsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("这次修改还没有保存。") }
    }
}
