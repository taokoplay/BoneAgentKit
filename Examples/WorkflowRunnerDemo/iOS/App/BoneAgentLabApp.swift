import SwiftUI

@main
struct BoneAgentLabApp: App {
    @State private var workspace: LabWorkspaceModel
    @State private var hasRunPublicDiagnostic = false
    @State private var hasRunFileDiagnostic = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        let testing = ProcessInfo.processInfo.arguments.contains("--live-chat-ui-test")
        #else
        let testing = false
        #endif
        let store = LiveChatSettingsStore(isUITesting: testing)
        let chat = LiveChatModel(isUITesting: testing)
        let workspace = LabWorkspaceModel(store: store, chat: chat)
        #if DEBUG
        if !testing && ProcessInfo.processInfo.arguments.contains("--prepare-baidu-search-for-task") {
            _ = workspace.enableBaiduForNextTask()
        }
        if testing && ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") {
            workspace.selectedTab = .chat; workspace.labPath = []
        }
        #endif
        _workspace = State(initialValue: workspace)
    }
    var body: some Scene {
        WindowGroup { tabShell }
    }
    private var tabShell: some View {
        TabView(selection: $workspace.selectedTab) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right", value: LabWorkspaceModel.Tab.chat) {
                NavigationStack { LiveChatView(model: workspace.chat, store: workspace.store, workspace: workspace) }
            }
            Tab("实验室", systemImage: "square.stack.3d.up", value: LabWorkspaceModel.Tab.laboratory) {
                NavigationStack(path: $workspace.labPath) {
                    SDKCapabilitiesLabView(workspace: workspace)
                        .navigationDestination(for: LabWorkspaceModel.Destination.self, destination: destinationView)
                }
            }
        }
        .tint(LabStyle.accent)
        .sheet(item: $workspace.configuration) { destination in
            NavigationStack { configurationView(destination) }
                .id(destination.id)
                .presentationDragIndicator(.visible)
        }
        .modifier(LiveToolInteractionPresenter(model: workspace.chat.interactions))
        .alert("开始新对话并运行？", isPresented: $workspace.confirmsNewRun) {
            Button("开始并运行", action: workspace.confirmNewRun).accessibilityIdentifier("confirmNewToolRun")
            Button("取消", role: .cancel, action: workspace.cancelNewRun)
        } message: {
            Text("需要重新开始对话。消息历史会清空，任务草稿和未发送材料会保留。")
        }
        .alert("替换当前任务？", isPresented: $workspace.confirmsValidationReplacement) {
            Button("使用测试任务", action: workspace.confirmValidationReplacement)
                .accessibilityIdentifier("confirmValidationTemplate")
            Button("保留草稿", role: .cancel, action: workspace.cancelValidationReplacement)
        } message: {
            Text("会替换当前任务文字。计算测试会勾选计算器；点击运行前不会发送请求。")
        }
        .task {
            await workspace.chat.prepare(store: workspace.store)
            #if DEBUG
            if workspace.chat.isUITesting && !hasRunPublicDiagnostic &&
                ProcessInfo.processInfo.arguments.contains("--baidu-public-page-ui-test") &&
                ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") {
                hasRunPublicDiagnostic = true
                await BaiduPublicPageDiagnostic.run(reader: workspace.chat.browserSearch)
            }
            if workspace.chat.isUITesting && !hasRunFileDiagnostic &&
                ProcessInfo.processInfo.arguments.contains("--file-recovery-ui-test") &&
                (ProcessInfo.processInfo.arguments.contains("--run-file-recovery-diagnostic") ||
                 ProcessInfo.processInfo.arguments.contains("--seed-file-recovery-ui-state")) {
                hasRunFileDiagnostic = true
                await FileRecoveryDiagnostic.run(workspace: workspace,
                    completeFlow: ProcessInfo.processInfo.arguments.contains("--run-file-recovery-diagnostic"))
            }
            if workspace.chat.isUITesting && !hasRunFileDiagnostic &&
                ProcessInfo.processInfo.arguments.contains("--context-capacity-ui-test") &&
                ProcessInfo.processInfo.arguments.contains("--run-model-capacity-diagnostic") {
                hasRunFileDiagnostic = true
                await ModelCapacityDiagnostic.run(workspace: workspace)
            }
            #endif
        }
        .onChange(of: workspace.chat.isSending) { _, sending in
            if !sending { workspace.recoverRejectedInputIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { workspace.store.refreshCredentialAvailability() }
            else { workspace.chat.browserSearch.cancel() }
        }
        #if DEBUG
        .modifier(LabUITestAppearance(isTesting: workspace.chat.isUITesting))
        #endif
    }
    @ViewBuilder
    private func destinationView(_ destination: LabWorkspaceModel.Destination) -> some View {
        switch destination {
        case .tools:
            LabToolWorkbenchView(workspace: workspace)
        case .structured:
            StructuredOutputLabView(store: workspace.store, onConfigureModel: { workspace.openConfiguration(.model) })
        case .workflow:
            LiveWorkflowLabView(store: workspace.store,
                calculatorEnabled: workspace.selectedPlan.groups.contains(.calculator),
                onConfigureModel: { workspace.openConfiguration(.model) }, onConfigureTools: workspace.openTools)
        case .textResource:
            TextResourceLabView(canUseInTask: workspace.canEdit, onUseInTask: { name, text in
                await workspace.useResource(name: name, text: text)
            })
        case .localModels:
            LocalModelLabView()
        case .validationResult:
            LabValidationResultView(model: workspace.validation, isUITesting: workspace.store.isUITesting)
        case .search:
            LabSearchView(workspace: workspace)
        }
    }
    @ViewBuilder
    private func configurationView(_ destination: LabWorkspaceModel.Configuration) -> some View {
        switch destination {
        case .settings:
            LabSettingsView(workspace: workspace)
        case .instructions:
            LabInstructionSettingsView(store: workspace.store, onSaved: workspace.configurationSaved)
        case .model:
            LiveModelSettingsView(store: workspace.store, onSaved: workspace.configurationSaved,
                                  onManageTools: workspace.openTools)
        case .network:
            ToolNetworkSettingsView(store: workspace.store, onSaved: workspace.configurationSaved)
        case .guide(let group):
            LabToolGuideView(workspace: workspace, group: group)
        }
    }
}
