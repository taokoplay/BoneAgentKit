import SwiftUI
import UniformTypeIdentifiers
import BoneAgentTools

struct LabToolWorkbenchView: View {
    @Bindable var workspace: LabWorkspaceModel
    let showsSpecialExperiments: Bool
    @State private var showsTextImporter = false
    @State private var previewFileResource: DemoImportedFileResource?
    @State private var previewResource: DemoImportedTextResource?
    @State private var toolsExpanded: Bool
    @FocusState private var isTaskFocused: Bool

    init(workspace: LabWorkspaceModel, showsSpecialExperiments: Bool = false) {
        self.workspace = workspace
        self.showsSpecialExperiments = showsSpecialExperiments
        _toolsExpanded = State(initialValue: !showsSpecialExperiments)
    }

    var body: some View {
        Form {
            if showsSpecialExperiments {
                modelSection
                taskSection
            }
            toolSection
            if !workspace.requirements.isEmpty { requirementsSection }
            if showsSpecialExperiments {
                resultSection
                if let message = workspace.errorMessage { errorRow(message, id: "labTaskError") }
                if let message = workspace.chat.errorMessage, workspace.validationKind == nil {
                    errorRow(message, id: "labAttachmentError")
                }
                if let message = workspace.validation.errorMessage { errorRow(message, id: "labValidationError") }
                if let notice = workspace.notice {
                    Text(notice).font(.subheadline).foregroundStyle(.secondary).accessibilityIdentifier("labTaskNotice")
                }
                moreSection
            }
        }
        .navigationTitle(showsSpecialExperiments ? "实验室" : "选择工具")
        .navigationBarTitleDisplayMode(showsSpecialExperiments ? .large : .inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isTaskFocused {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { isTaskFocused = false }
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("labTaskKeyboardDone")
                } else {
                    Button("设置", systemImage: "slider.horizontal.3") { workspace.openConfiguration(.settings) }
                        .disabled(!workspace.canEdit).accessibilityIdentifier("labSharedSettings")
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsSpecialExperiments { primaryAction }
            else {
                Button("完成工具选择") {
                    if workspace.labPath.last == .tools { workspace.labPath.removeLast() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(16).background(.bar)
                .accessibilityIdentifier("finishToolSelection")
            }
        }
        .fileImporter(isPresented: $showsTextImporter, allowedContentTypes: [.item],
                      allowsMultipleSelection: false, onCompletion: importFile)
        .sheet(item: $previewResource) { resource in
            NavigationStack {
                LiveTextResourcePreviewView(resource: resource) { offset in
                    try await workspace.chat.readLocalTextPage(resource, offset: offset)
                }
            }
        }
        .sheet(item: $previewFileResource) { resource in
            NavigationStack {
                LiveFileResourcePreviewView(resource: resource, model: workspace.chat)
            }
        }
    }

    private var modelSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                SDKProviderIcon(provider: workspace.store.settings.provider, size: 28)
                VStack(alignment: .leading, spacing: 4) {
                    Text(workspace.store.settings.modelID.isEmpty ? "先设置一个模型" : workspace.store.settings.modelID)
                        .font(.headline).textSelection(.enabled)
                    Text(workspace.store.hasKey ? workspace.store.settings.provider.title : "尚未填写 API Key")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("labModelStatus")
                }
            }
            Button("模型与工具设置", systemImage: "slider.horizontal.3") {
                isTaskFocused = false
                workspace.openConfiguration(.settings)
            }
            .frame(minHeight: 44).disabled(!workspace.canEdit).accessibilityIdentifier("labModelSetup")
            Button("搜索资料", systemImage: "magnifyingglass") {
                isTaskFocused = false; workspace.openSearch()
            }
            .frame(minHeight: 44).accessibilityIdentifier("openLabSearch")
        } footer: { Text("对话和测试共用这套设置。") }
        .listRowBackground(LabStyle.surface)
    }

    private var taskSection: some View {
        Section {
            Menu {
                Button("普通任务") { workspace.useOrdinaryTask() }
                    .accessibilityIdentifier("validationTemplate_none")
                ForEach(DemoValidationKind.allCases) { kind in
                    Button(kind.title, systemImage: kind.symbol) { workspace.requestValidation(kind) }
                        .accessibilityIdentifier("validationTemplate_\(kind.id)")
                }
            } label: {
                LabeledContent("任务类型", value: workspace.validationKind?.title ?? "普通任务")
                    .frame(minHeight: 44)
            }
            .disabled(!workspace.canEdit).accessibilityIdentifier("validationTaskMenu")
            if let kind = workspace.validationKind {
                Text(kind.explanation).font(.subheadline).foregroundStyle(.secondary)
                if kind == .instructions {
                    Button("修改助手说明", systemImage: "text.bubble") { workspace.openConfiguration(.instructions) }
                        .frame(minHeight: 44).disabled(!workspace.canEdit)
                        .accessibilityIdentifier("validationEditInstructions")
                    TextField("回答应包含的文字（可选）", text: $workspace.validationExpectedText)
                        .focused($isTaskFocused).disabled(!workspace.canEdit)
                        .accessibilityIdentifier("validationExpectedText")
                    Text("只检查这段文字是否出现在回答中；留空时由你检查。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            TextField("写下希望模型完成的任务…", text: $workspace.taskText, axis: .vertical)
                .lineLimit(3...8).frame(minHeight: 100, alignment: .topLeading)
                .focused($isTaskFocused).disabled(!workspace.canEdit)
                .accessibilityLabel("任务内容").accessibilityIdentifier("labTaskInput")
            if workspace.taskText.utf8.count > 12_288 {
                Text("\(workspace.taskText.utf8.count) / 16384 字节")
                    .font(.caption).foregroundStyle(workspace.taskText.utf8.count > 16_384 ? Color.red : Color.secondary)
                    .accessibilityIdentifier("labTaskByteCount")
            }
            if workspace.validationKind == nil {
                if workspace.hasDraftAttachments {
                    LiveChatAttachmentsView(images: workspace.draftImages, resources: workspace.draftResources,
                        fileResources: workspace.draftFileResources,
                        removeImage: workspace.removeDraftImage, removeResource: workspace.removeDraftResource,
                        removeFileResource: workspace.removeDraftFileResource,
                        onPreviewResource: { previewResource = $0 },
                        onPreviewFileResource: { previewFileResource = $0 })
                        .disabled(!workspace.canEdit)
                }
                Button("添加文件材料", systemImage: "doc.badge.plus") {
                    isTaskFocused = false
                    workspace.selectResources()
                    showsTextImporter = true
                }
                .frame(minHeight: 44).disabled(!workspace.canEdit).accessibilityIdentifier("labImportText")
            }
            if workspace.validation.isRunning { ProgressView(workspace.validation.statusTitle) }
            if workspace.store.isUITesting {
                Label("界面测试数据 · 未联网", systemImage: "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: { Text("任务与测试") }
          footer: {
              Text(workspace.validationKind == nil
                   ? "点击运行后才发送。需要工具时，展开下方工具选择。"
                   : "测试会请求当前模型，费用由服务商计算。使用独立会话，保留你的聊天、草稿和待发附件。")
          }
        .listRowBackground(LabStyle.surface)
    }

    private var toolSection: some View {
        Section {
            DisclosureGroup(isExpanded: $toolsExpanded) {
                Menu {
                    ForEach(BoneBuiltInToolPreset.allCases) { preset in
                        Button(preset.title) { workspace.selectPreset(preset) }
                            .accessibilityIdentifier("toolPreset_\(preset.id)")
                    }
                    Button("清空选择") { workspace.clearSelection() }.accessibilityIdentifier("toolPreset_clear")
                } label: { Label("快速选择", systemImage: "checklist").frame(minHeight: 44) }
                .disabled(!workspace.canEdit).accessibilityIdentifier("toolPresetMenu")
                ForEach(workspace.choices) { choice in LabToolChoiceRow(workspace: workspace, choice: choice) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("工具 · 已选 \(workspace.selectedPlan.groups.count) 类").font(.headline)
                        .accessibilityIdentifier("labSelectedToolCount")
                    Text(workspace.selectedPlan.summary).font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("labToolChoices")
            if workspace.hasSelectionChanges {
                Text("下次运行时使用当前选择。")
                    .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("labSelectionStatus")
            }
        } footer: { Text("模型按需调用工具。网站访问和搜索会在调用前询问你。") }
        .listRowBackground(LabStyle.surface)
    }

    private var requirementsSection: some View {
        Section("还需设置") {
            ForEach(workspace.requirements) { requirement in
                VStack(alignment: .leading, spacing: 4) {
                    Text(requirement.message).font(.subheadline).foregroundStyle(.secondary)
                    Button(requirement.actionTitle) { isTaskFocused = false; workspace.resolve(requirement) }
                        .frame(minHeight: 44).disabled(!workspace.canEdit)
                        .accessibilityIdentifier("labRequirement_\(requirement.kind.rawValue)")
                }
            }
        }
        .listRowBackground(LabStyle.surface)
    }

    private var resultSection: some View {
        Section("结果") {
            if let report = workspace.validation.report {
                NavigationLink(value: LabWorkspaceModel.Destination.validationResult) {
                    Label("\(report.request.kind.title) · \(report.verdict.title)", systemImage: "checklist")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("labValidationResult")
            }
            Button { isTaskFocused = false; workspace.openChat() } label: {
                Label(workspace.latestResultTitle, systemImage: "bubble.left.and.bubble.right").frame(minHeight: 44)
            }
            .accessibilityIdentifier("labViewResult")
        }
        .listRowBackground(LabStyle.surface)
    }

    private var primaryAction: some View {
        Button {
            isTaskFocused = false
            workspace.performPrimaryAction()
        } label: {
            Label(workspace.primaryTitle, systemImage: workspace.validation.isRunning ? "stop.fill" : "play.fill")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                .multilineTextAlignment(.center)
        }
        .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent).controlSize(.large)
        .disabled(!workspace.canPerformPrimary).accessibilityIdentifier("labRunTask")
        .padding(.horizontal, LabStyle.pageInset).padding(.vertical, 12).background(.bar)
    }

    private var moreSection: some View {
        Section {
            DisclosureGroup("更多能力") {
                NavigationLink("检查 JSON 结果", value: LabWorkspaceModel.Destination.structured)
                    .frame(minHeight: 44).accessibilityIdentifier("structuredOutputLab")
                NavigationLink("查看任务执行状态", value: LabWorkspaceModel.Destination.workflow)
                    .frame(minHeight: 44).accessibilityIdentifier("liveWorkflowLab")
                NavigationLink("预览与导入资料", value: LabWorkspaceModel.Destination.textResource)
                    .frame(minHeight: 44).accessibilityIdentifier("textResourceLab")
                NavigationLink("本地模型文件", value: LabWorkspaceModel.Destination.localModels)
                    .frame(minHeight: 44).accessibilityIdentifier("localModelLab")
            }
            .disabled(!workspace.canEdit).accessibilityIdentifier("moreLabCapabilities")
        }
        .listRowBackground(LabStyle.surface)
    }

    private func errorRow(_ message: String, id: String) -> some View {
        Text(message).font(.subheadline).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier(id)
    }

    /// 导入任意文件并把统一资源加入当前实验室任务草稿。
    /// - Parameter result: 系统文件选择器返回的单个授权 URL。
    private func importFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { workspace.chat.reportAttachmentError(); return }
            Task { @MainActor in
                guard workspace.canEdit else { workspace.chat.reportAttachmentError(); return }
                workspace.selectResources()
                var settings = workspace.selectedPlan.applying(to: workspace.store.settings)
                settings.enablesTextResources = true
                let previous = workspace.chat.pendingFileResources.count
                await workspace.chat.importFile(url: url, settings: settings)
                if workspace.chat.pendingFileResources.count == previous && workspace.chat.errorMessage == nil {
                    workspace.chat.reportAttachmentError()
                }
            }
        case .failure: workspace.chat.reportAttachmentError()
        }
    }
}
