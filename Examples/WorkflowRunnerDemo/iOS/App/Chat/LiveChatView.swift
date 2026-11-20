import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import BoneAgentTools

struct LiveChatView: View {
    private struct ScrollDimensions: Equatable {
        let contentHeight: CGFloat
        let viewportHeight: CGFloat
    }
    let model: LiveChatModel
    let store: LiveChatSettingsStore
    @Bindable var workspace: LabWorkspaceModel
    @State private var showsStatistics = false
    @State private var showsTextImporter = false
    @State private var previewFileResource: DemoImportedFileResource?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var previewResource: DemoImportedTextResource?
    private var loadingPhoto: Bool { workspace.isLoadingPhoto }
    @State private var confirmsNewConversation = false
    @State private var isNearBottom = true
    @State private var followsLatest = true
    @State private var userIsScrolling = false
    @FocusState private var composing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: LabStyle.sectionSpacing) {
                    connectionHeader
                    toolPlanHeader
                    if model.messages.isEmpty && !model.isSending && !workspace.isApplying { welcome }
                    ForEach(model.messages) { message in
                        LiveChatBubble(message: message, provider: model.conversationProvider ?? store.settings.provider,
                            images: model.images.filter { message.imageIDs.contains($0.id) },
                            resources: model.resources.filter { message.resourceIDs.contains($0.id) },
                            fileResources: model.fileResources.filter { message.fileResourceIDs.contains($0.id) },
                            onPreviewResource: { previewResource = $0 },
                            onPreviewFileResource: { previewFileResource = $0 })
                    }
                    if model.isPreparing { ProgressView("准备本机会话…") }
                    if workspace.isApplying && !model.isPreparing && !model.isSending { ProgressView("准备任务…") }
                    if model.isSending { streamingReply }
                    if workspace.selectedTab == .chat && !workspace.search.isWorking &&
                        (model.browserSearch.active != nil || model.browserSearch.lastSnapshot != nil || model.browserSearch.message != nil) {
                        LiveBrowserSearchView(model: model.browserSearch)
                            .padding(16).background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
                    }
                    if let notice = model.notice {
                        Label(notice, systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("chatNotice")
                        if model.needsNewConversation && model.errorMessage == nil { restartButton }
                    }
                    if let error = model.errorMessage { errorCard(error) }
                    if let error = workspace.errorMessage, error != model.errorMessage {
                        Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                            .accessibilityIdentifier("workspaceError")
                    }
                    if let retained = workspace.retainedTask {
                        DisclosureGroup("保留的任务") {
                            Text(retained.text).textSelection(.enabled)
                            taskMaterials(retained)
                            Button("重试保留任务", action: workspace.retryRetainedTask)
                                .frame(minHeight: 44).disabled(!workspace.canEdit)
                                .accessibilityIdentifier("retryRetainedTask")
                        }
                        .font(.subheadline).accessibilityIdentifier("unsentTask")
                    }
                    Color.clear.frame(height: 1).id("chatBottom")
                }
                .padding(LabStyle.pageInset)
            }
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, phase in
                userIsScrolling = phase == .interacting || phase == .decelerating
                if phase == .idle && isNearBottom {
                    followsLatest = true
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.contentOffset.y - geometry.containerSize.height < 100
            } action: { _, nearBottom in
                isNearBottom = nearBottom
                if userIsScrolling { followsLatest = nearBottom }
            }
            .onScrollGeometryChange(for: ScrollDimensions.self) { geometry in
                ScrollDimensions(contentHeight: geometry.contentSize.height,
                                 viewportHeight: geometry.containerSize.height)
            } action: { _, _ in
                if followsLatest && !userIsScrolling && !composing { scrollToBottom(reader, animated: false) }
            }
            .onChange(of: model.messages.count) { _, count in
                if count == 0 || (followsLatest && !userIsScrolling) { scrollToBottom(reader) }
            }
            .onChange(of: model.isSending) { _, _ in
                if followsLatest && !userIsScrolling { scrollToBottom(reader) }
            }
            .onChange(of: model.partialReply) { _, _ in
                if followsLatest && !userIsScrolling && !composing { scrollToBottom(reader, animated: false) }
            }
            .onChange(of: model.browserSearch.active?.id) { _, id in
                if id != nil && !workspace.search.isWorking && followsLatest && !userIsScrolling {
                    scrollToBottom(reader, animated: false)
                }
            }
            .onChange(of: model.errorMessage) { _, _ in
                if followsLatest && !userIsScrolling { scrollToBottom(reader) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 8) {
                    if !followsLatest && !model.messages.isEmpty {
                        Button("回到最新消息", systemImage: "arrow.down") { scrollToBottom(reader) }
                            .font(.subheadline)
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("latestMessage")
                    }
                    composer
                }
            }
        }
        .background(LabStyle.canvas)
        .navigationTitle("Agent Lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("新对话", systemImage: "square.and.pencil") {
                    if model.messages.isEmpty && workspace.taskText.isEmpty && !workspace.hasDraftAttachments &&
                        workspace.retainedTask == nil && workspace.retryableTask == nil { startNewConversation() }
                    else { composing = false; confirmsNewConversation = true }
                }
                .disabled(!workspace.canEdit || loadingPhoto)
                .accessibilityIdentifier("newConversation")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if !composing {
                    Button("搜索", systemImage: "magnifyingglass", action: workspace.openSearch)
                        .accessibilityIdentifier("chatOpenSearch")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("运行统计", systemImage: "chart.bar") {
                    composing = false
                    showsStatistics = true
                }
                .accessibilityIdentifier("chatStatistics")
            }
            ToolbarItem(placement: .topBarTrailing) {
                if composing {
                    Button("收起键盘", systemImage: "keyboard.chevron.compact.down") { composing = false }
                        .accessibilityIdentifier("dismissChatKeyboard")
                } else {
                    Button("设置", systemImage: "slider.horizontal.3", action: openSettings)
                        .disabled(!workspace.canEdit || loadingPhoto)
                        .accessibilityIdentifier("modelSettings")
                }
            }
        }
        .sheet(isPresented: $showsStatistics) {
            NavigationStack { LiveChatStatisticsView(model: model, settings: store.settings) }
        }
        .sheet(item: $previewResource) { resource in
            NavigationStack {
                LiveTextResourcePreviewView(resource: resource) { offset in
                    try await model.readLocalTextPage(resource, offset: offset)
                }
            }
        }
        .sheet(item: $previewFileResource) { resource in
            NavigationStack {
                LiveFileResourcePreviewView(resource: resource, model: model)
            }
        }
        .fileImporter(isPresented: $showsTextImporter, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task {
                        var settings = store.settings
                        settings.enablesTextResources = workspace.selectedPlan.groups.contains(.resources)
                        await model.importFile(url: url, settings: settings)
                    }
                }
            case .failure: model.reportAttachmentError()
            }
        }
        .onChange(of: selectedPhoto) { _, photo in
            guard let photo else { return }
            workspace.isLoadingPhoto = true
            Task {
                defer { selectedPhoto = nil; workspace.isLoadingPhoto = false }
                do {
                    guard let data = try await photo.loadTransferable(type: Data.self) else {
                        model.reportAttachmentError()
                        return
                    }
                    await model.importImage(data: data, settings: store.settings)
                } catch { model.reportAttachmentError() }
            }
        }
        .onChange(of: model.interactions.pending?.id) { _, pendingID in
            if pendingID != nil { composing = false; showsStatistics = false }
        }
        .onChange(of: workspace.selectedTab) { _, tab in
            if tab != .chat { composing = false }
        }
        .alert("开始新对话？", isPresented: $confirmsNewConversation) {
            Button("开始新对话", role: .destructive, action: startNewConversation)
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前消息和输入草稿会被清空。模型设置会保留。")
        }
    }

    private var connectionHeader: some View {
        Button(action: openSettings) {
            HStack(spacing: LabStyle.itemSpacing) {
                SDKProviderIcon(provider: store.settings.provider, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.settings.provider.title).font(.headline)
                    Text(store.hasKey ? store.settings.modelID : "设置 API Key 后开始对话")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.subheadline.bold()).foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!workspace.canEdit || loadingPhoto)
        .accessibilityHint("打开模型设置")
        .accessibilityIdentifier("connectionSettings")
    }

    private var toolPlanHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                composing = false
                workspace.openTools()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "checklist").foregroundStyle(LabStyle.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("下次发送 · \(workspace.selectedPlan.toolCount) 个工具").font(.subheadline.bold())
                        Text(workspace.selectedPlan.summary).font(.footnote).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain).foregroundStyle(.primary)
            .disabled(!workspace.canEdit)
            .accessibilityIdentifier("chatToolSelection")
            if workspace.hasSelectionChanges {
                Text("所选工具将在发送前应用；需要切换会话时会先确认。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let requirement = workspace.requirements.first {
                Button(requirement.actionTitle) {
                    composing = false
                    workspace.resolve(requirement)
                }
                .font(.subheadline).frame(minHeight: 44).disabled(!workspace.canEdit)
            }
            Text("百度搜索并回答无需搜索 API Key。一次任务确认后，公开结果与来源会交给当前模型；模型调用仍按模型账户计费。也可手动浏览百度、必应并选取文字。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("chatSearchCapabilityNotice")
            Button("百度搜索并回答", systemImage: "sparkle.magnifyingglass") {
                composing = false
                followsLatest = true
                workspace.searchBaiduAndAnswer()
            }
            .frame(minHeight: 44).buttonStyle(.bordered).disabled(!workspace.canEdit)
            .accessibilityIdentifier("chatBaiduAnswer")
            HStack(spacing: 16) {
                Button("百度网页搜索") {
                    composing = false
                    if workspace.recoverFailedTask() { workspace.openBrowserSearch(using: .baidu, for: workspace.taskText) }
                }
                .frame(minHeight: 44).accessibilityIdentifier("chatPrepareManualSearch")
                Button("选择自动搜索") { composing = false; workspace.openTools() }
                    .frame(minHeight: 44).accessibilityIdentifier("chatChooseAutomaticSearch")
            }
            .font(.subheadline).buttonStyle(.borderless).disabled(!workspace.canEdit)
        }
        .padding(16).background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
    }

    private var welcome: some View {
        VStack(spacing: LabStyle.sectionSpacing) {
            VStack(spacing: 16) {
                Image("LabMark").resizable().scaledToFit()
                    .frame(width: 64, height: 64)
                    .clipShape(.rect(cornerRadius: LabStyle.controlRadius))
                    .accessibilityHidden(true)
                Text(store.hasKey ? "从一个问题开始" : "连接模型，开始对话")
                    .font(.title2.bold())
                Text(store.hasKey ? "聊一个想法，或用工具验证一个结果。" : "选择服务商和模型，填入你的 API Key。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !store.hasKey {
                    Button("设置模型", systemImage: "key", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(LabStyle.onAccent)
                        .controlSize(.large)
                }
            }
            .padding(.vertical, 24)
            if store.hasKey && workspace.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(spacing: LabStyle.itemSpacing) {
                    suggestion("介绍一下你自己", detail: "用一句话认识当前模型", symbol: "bubble.left",
                               prompt: "请用一句话介绍你自己。")
                    if workspace.selectedPlan.groups.contains(.calculator) {
                        suggestion("试试计算器", detail: "计算 128 × 36，并解释结果", symbol: "function",
                                   prompt: "请调用计算器工具计算 128 × 36，再用一句话解释结果。")
                    } else {
                        suggestion("梳理一个想法", detail: "把模糊的问题整理成下一步", symbol: "list.bullet",
                                   prompt: "我想开始一个新项目，请先问我三个关键问题，帮我梳理下一步。")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func suggestion(_ title: String, detail: String, symbol: String, prompt: String) -> some View {
        Button {
            guard workspace.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            workspace.taskText = prompt
            composing = true
        } label: {
            HStack(spacing: LabStyle.itemSpacing) {
                Image(systemName: symbol).foregroundStyle(LabStyle.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.primary)
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left").foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("填入消息，确认后发送")
    }

    private func errorCard(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: LabStyle.itemSpacing) {
            Label(error, systemImage: "exclamationmark.circle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("chatError")
            if let failure = model.toolFailure, error == failure.title {
                Text(failure.message).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chatToolFailureDetail")
                if failure.requiresOutcomeReview && failure.reason != .outcomeUnconfirmed {
                    Text(DemoToolFailure.Reason.outcomeUnconfirmed.message)
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if failure.tool == .resourceRead && failure.reason == .invalidArguments {
                    Text("文件与原问题仍在当前 App 中。点击下方文件名可直接本机预览；重试原任务会保留输入框中的另一条草稿。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("resourceReadRecoveryHint")
                } else {
                    Button(failure.needsNetworkSettings ? "检查搜索与网站权限" : "检查工具选择") {
                        composing = false
                        if failure.needsNetworkSettings { workspace.openConfiguration(.network) }
                        else { workspace.openTools() }
                    }
                    .frame(minHeight: 44).disabled(!workspace.canEdit)
                    .accessibilityIdentifier("chatToolFailureSettings")
                }
                if failure.offersSearch {
                    if !model.failureHadAutomaticSearch {
                        Text("本次未启用联网搜索，网页正文读取不能替代关键词搜索。可用百度搜索并回答，无需 DeepSeek 搜索 Key；会保留其他草稿并确认新任务。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("百度搜索并回答原问题", systemImage: "sparkle.magnifyingglass") {
                            composing = false; followsLatest = true
                            workspace.retryFailedTaskWithBaidu()
                        }
                        .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent)
                        .frame(minHeight: 44).disabled(!workspace.canEdit)
                        .accessibilityIdentifier("chatToolFailureBaiduAnswer")
                    }
                    Button("搜索资料", systemImage: "magnifyingglass") {
                        composing = false
                        if workspace.recoverFailedTask() { workspace.openSearch(for: model.failedTaskText ?? workspace.taskText) }
                    }
                    .frame(minHeight: 44).disabled(!workspace.canEdit)
                    .accessibilityIdentifier("chatToolFailureSearch")
                }
            }
            if let task = workspace.retryableTask {
                Text("原问题与关联材料已保留。重试只发送此任务，输入框里的另一条草稿会保留。")
                    .font(.subheadline).foregroundStyle(.secondary)
                taskMaterials(task)
                Button("重试原任务", systemImage: "arrow.clockwise") {
                    composing = false; workspace.retryFailedTask()
                }
                .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent)
                .frame(minHeight: 44).disabled(!workspace.canEdit)
                .accessibilityIdentifier("retryFailedTask")
                Button("取回原问题") { _ = workspace.recoverFailedTask() }
                    .frame(minHeight: 44).disabled(!workspace.canEdit)
                    .accessibilityIdentifier("recoverFailedTask")
            }
            if model.needsNewConversation { restartButton }
            if let diagnostic = model.failureDiagnostic {
                RunFailureDiagnosticView(diagnostic: diagnostic)
                if diagnostic.code == .outputTruncated {
                    Menu {
                        ForEach(store.settings.replyLimitChoices, id: \.self) { limit in
                            Button("\(limit) Token") { workspace.setReplyLimit(limit) }
                                .accessibilityIdentifier("replyLimit_\(limit)")
                        }
                    } label: {
                        Label("下次回复上限：\(store.settings.maximumOutputTokens) Token", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .frame(minHeight: 44)
                    }
                    .disabled(!workspace.canEdit).accessibilityIdentifier("truncationReplyBudget")
                    Text("选择后不自动重发。更长回复可能增加模型用量；文件原文可直接在本机预览。")
                        .font(.footnote).foregroundStyle(.secondary)
                    let capacity = store.settings.modelCapacity
                    Text("模型最大输出：\(capacity.maximumOutputTokens.map { String($0) } ?? "未知") Token；本次使用 \(diagnostic.maximumReplyTokens) Token。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if capacity.outputIncludesThinking {
                        Text("该型号的思考与正文共用输出预算，默认深度思考可能先耗尽 1024 Token。上下文压缩不会提高输出预算。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let output = capacity.recommendedOutputTokens, let window = capacity.contextWindowTokens {
                        Button("采用模型建议：输出 \(output)，窗口 \(window) Token", action: workspace.useRecommendedModelCapacity)
                            .frame(minHeight: 44).disabled(!workspace.canEdit)
                            .accessibilityIdentifier("applyModelCapacityRecommendation")
                        Text("仅保存上述预算，不自动重试，也不启用模型摘要。更大预算可能增加用量，仍受任务时限和字节额度限制。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let unfinished = model.unfinishedReply {
                    DisclosureGroup("未完成内容（未提交）") {
                        Text(unfinished).textSelection(.enabled)
                    }
                    .font(.subheadline).accessibilityIdentifier("unfinishedReply")
                }
                if diagnostic.code == .outputTruncated || diagnostic.code == .contextManagement {
                    Button("检查模型设置", action: openSettings)
                        .frame(minHeight: 44).disabled(!workspace.canEdit)
                }
            }
            if let logError = model.diagnosticLogError {
                Text(logError).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
    }

    private func taskMaterials(_ task: DemoChatTaskBundle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.resources.filter { task.materials.resourceIDs.contains($0.id) }) { resource in
                Button { previewResource = resource } label: {
                    Label(resource.name, systemImage: "doc.text.magnifyingglass").frame(minHeight: 44)
                }
                .accessibilityIdentifier("previewRetainedResource_\(resource.id)")
            }
            ForEach(model.fileResources.filter { task.materials.fileResourceIDs.contains($0.id) }) { resource in
                Button { previewFileResource = resource } label: {
                    Label(resource.name, systemImage: "doc.richtext.magnifyingglass").frame(minHeight: 44)
                }
                .accessibilityIdentifier("previewRetainedFileResource_\(resource.id)")
            }
            if !task.materials.imageIDs.isEmpty {
                Text("关联图片：\(task.materials.imageIDs.count) 张").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var restartButton: some View {
        Button("开始新对话", systemImage: "square.and.pencil") {
            workspace.prepareNewConversation()
            isNearBottom = true
            followsLatest = true
        }
        .buttonStyle(.bordered).controlSize(.large)
        .disabled(model.isBusy || loadingPhoto)
        .accessibilityIdentifier("restartChat")
    }

    private var streamingReply: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.statusTitle).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chatRunStatus")
            }
            if !model.partialReply.isEmpty {
                Text(model.partialReply).font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("streamingReply")
                Text("生成中 · 完成后可复制和分享")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    private var searchStatusTitle: String {
        guard workspace.selectedPlan.groups.contains(.webSearch) else { return "未启用联网搜索" }
        let search = store.settings.search
        guard search.automaticEnabled else { return "联网搜索待配置" }
        if search.automaticChannel.requiresAPIKey && !store.hasAutomaticSearchKey {
            return "\(search.automaticChannel.title) · 缺少搜索 Key"
        }
        return "\(search.automaticChannel.title) · 已选择"
    }

    private var composer: some View {
        VStack(spacing: 8) {
            HStack(alignment: .center) {
                Label(searchStatusTitle, systemImage: "globe")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("composerSearchStatus")
                Spacer(minLength: 8)
                Button(workspace.selectedPlan.groups.contains(.webSearch) ? "搜索设置" : "启用百度搜索") {
                    composing = false
                    if workspace.selectedPlan.groups.contains(.webSearch) { workspace.openConfiguration(.network) }
                    else { _ = workspace.enableBaiduForNextTask() }
                }
                .font(.subheadline).frame(minHeight: 44).disabled(!workspace.canEdit)
                .accessibilityIdentifier("composerEnableBaiduSearch")
            }
            if workspace.search.isWorking {
                Button("搜索进行中 · 查看进度", action: workspace.openSearch).font(.subheadline).frame(minHeight: 44)
            }
            if workspace.validation.isRunning {
                Button("实验室正在测试 · 查看进度") { composing = false; workspace.selectedTab = .laboratory }
                    .font(.subheadline).frame(minHeight: 44)
            }
            if workspace.hasDraftAttachments {
                LiveChatAttachmentsView(images: workspace.draftImages, resources: workspace.draftResources,
                    fileResources: workspace.draftFileResources,
                    removeImage: workspace.removeDraftImage, removeResource: workspace.removeDraftResource,
                    removeFileResource: workspace.removeDraftFileResource,
                    onPreviewResource: { previewResource = $0 },
                    onPreviewFileResource: { previewFileResource = $0 })
                    .disabled(!workspace.canEdit || loadingPhoto)
                Text("附件仅在点击发送后上传。文本、PDF、Office、压缩包和二进制文件都按需分页读取。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.isImporting || loadingPhoto { ProgressView("在本机处理附件…").font(.footnote) }
            HStack(alignment: .bottom, spacing: 8) {
                if store.settings.visionPolicy != .disabled || workspace.selectedPlan.groups.contains(.resources) {
                    Menu {
                        if store.settings.visionPolicy != .disabled {
                            PhotosPicker(selection: $selectedPhoto, matching: .images, photoLibrary: .shared()) {
                                Label("选择图片", systemImage: "photo")
                            }
                        }
                        if workspace.selectedPlan.groups.contains(.resources) {
                            Button("导入文件", systemImage: "doc.badge.plus") {
                                composing = false
                                showsTextImporter = true
                            }
                        }
                    } label: {
                        Image(systemName: "plus.circle").font(.title2).frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(!workspace.canEdit || loadingPhoto)
                    .accessibilityLabel("添加附件")
                    .accessibilityIdentifier("chatAttachments")
                }
                TextField("输入消息…", text: $workspace.taskText, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .focused($composing)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityLabel("消息")
                    .accessibilityIdentifier("chatInput")
                if model.isSending {
                    Button("停止", systemImage: "stop.fill", action: model.stop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("stopMessage")
                } else {
                    Button("发送", systemImage: "arrow.up", action: send)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(LabStyle.onAccent)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!store.hasKey || model.isBusy || workspace.isApplying || loadingPhoto || workspace.validation.isRunning || workspace.search.isWorking ||
                                  (workspace.taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !workspace.hasDraftAttachments))
                        .accessibilityLabel(model.needsNewConversation ? "新对话并发送" : "发送")
                        .accessibilityIdentifier("sendMessage")
                }
            }
            .padding(8)
            .background(LabStyle.surface, in: .rect(cornerRadius: LabStyle.cardRadius))
            if !composing {
                Text(model.isUITesting ? "UI 测试替身 · 未联网" : "消息发送至所选服务商，费用由服务商计算")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(LabStyle.canvas)
    }

    private func openSettings() {
        composing = false
        workspace.openConfiguration(.settings)
    }

    private func startNewConversation() {
        guard workspace.canEdit && !loadingPhoto else { return }
        model.startNewConversation()
        workspace.clearTaskDraft()
        composing = false
        isNearBottom = true
        followsLatest = true
    }

    private func send() {
        guard !loadingPhoto else { return }
        workspace.performChatAction()
        isNearBottom = true
        followsLatest = true
    }

    private func scrollToBottom(_ reader: ScrollViewProxy, animated: Bool = true) {
        followsLatest = true
        withAnimation(animated && !reduceMotion ? .easeOut(duration: 0.2) : nil) {
            reader.scrollTo("chatBottom", anchor: .bottom)
        }
    }
}
