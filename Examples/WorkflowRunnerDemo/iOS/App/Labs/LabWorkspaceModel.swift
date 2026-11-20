import SwiftUI
import Observation
import BoneAgentTools

@Observable @MainActor
final class LabToolChoice: Identifiable {
    nonisolated let group: BoneBuiltInToolGroup
    var isSelected: Bool
    nonisolated var id: String { group.id }
    init(group: BoneBuiltInToolGroup, isSelected: Bool) { self.group = group; self.isSelected = isSelected }
}

@Observable @MainActor
final class LabWorkspaceModel {
    enum Tab: Hashable { case chat, laboratory }
    enum Destination: Hashable { case tools, structured, workflow, textResource, localModels, validationResult, search }
    enum Configuration: Identifiable, Equatable {
        case settings, model, network, instructions, guide(BoneBuiltInToolGroup)
        var id: String {
            switch self {
            case .model: "model"
            case .settings: "settings"
            case .instructions: "instructions"
            case .network: "network"
            case .guide(let group): "guide-\(group.id)"
            }
        }
    }
    let store: LiveChatSettingsStore
    let chat: LiveChatModel
    let validation = LiveValidationModel()
    let search: LabSearchModel
    var validationKind: DemoValidationKind?
    var validationExpectedText = ""
    var confirmsValidationReplacement = false
    let choices: [LabToolChoice]
    var selectedTab: Tab = .chat
    var labPath: [Destination] = []
    var taskText = ""
    var isLoadingPhoto = false
    var configuration: Configuration?
    var confirmsNewRun = false
    var confirmsExampleReplacement = false
    private(set) var isApplying = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    private(set) var retainedTask: DemoChatTaskBundle?
    private(set) var recoveredMaterials = DemoChatMaterials()
    var unsentTask: String? { retainedTask?.text }
    @ObservationIgnored private var configurationOpenedRevision: UInt64 = 0
    @ObservationIgnored private var transitionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingRun: RunIntent?
    @ObservationIgnored private var pendingExample: (text: String, group: BoneBuiltInToolGroup)?
    @ObservationIgnored private var pendingValidationKind: DemoValidationKind?

    private enum TaskSource: Equatable { case composer, failed(UUID), retained(UUID) }
    private struct RunIntent {
        let text: String
        let plan: DemoLabToolPlan
        let revision: UInt64
        let validationKind: DemoValidationKind?
        let expectedText: String
        let materials: DemoChatMaterials
        let source: TaskSource
    }
    init(store: LiveChatSettingsStore, chat: LiveChatModel) {
        self.store = store; self.chat = chat
        store.validateConversationPersistence = { [weak chat] enabled in
            try chat?.validatePersistence(enabled: enabled)
        }
        search = LabSearchModel(store: store)
        let plan = store.stagedToolPlan()
        choices = BoneBuiltInToolGroup.allCases.map { .init(group: $0, isSelected: plan.groups.contains($0)) }
        #if DEBUG
        // This isolated pipeline test seeds input without relying on device keyboard synthesis.
        if chat.isUITesting && ProcessInfo.processInfo.arguments.contains("--baidu-answer-ui-test") {
            taskText = "今天桐乡温度"
        }
        if chat.isUITesting && ProcessInfo.processInfo.arguments.contains("--baidu-public-page-ui-test") {
            try? store.selectBaiduWebSearchForTask()
            search.channel = .baiduWeb
            search.query = "今天深圳天气"
            selectedTab = .laboratory
            labPath = [.search]
        }
        #endif
    }
    var selectedPlan: DemoLabToolPlan { .init(groups: Set(choices.filter(\.isSelected).map(\.group))) }
    var hasSelectionChanges: Bool { selectedPlan != DemoLabToolPlan(settings: store.settings) }
    var canEdit: Bool { !isApplying && !isLoadingPhoto && !chat.isBusy && !validation.isRunning && !search.isWorking }
    var draftMaterials: DemoChatMaterials { chat.pendingMaterials.union(recoveredMaterials) }
    var draftResources: [DemoImportedTextResource] { chat.resources.filter { draftMaterials.resourceIDs.contains($0.id) } }
    /// 返回待发送的统一文件资源附件。
    var draftFileResources: [DemoImportedFileResource] { chat.fileResources.filter { draftMaterials.fileResourceIDs.contains($0.id) } }
    var draftImages: [DemoPreparedChatImage] { chat.images.filter { draftMaterials.imageIDs.contains($0.id) } }
    var hasDraftAttachments: Bool { !draftMaterials.isEmpty }
    var retryableTask: DemoChatTaskBundle? { chat.failedTask ?? chat.rejectedTask }
    private var protectedMaterials: DemoChatMaterials {
        draftMaterials.union(retainedTask?.materials ?? .init()).union(retryableTask?.materials ?? .init())
    }
    var requirements: [DemoLabRequirement] { requirements(for: validationKind == nil ? draftMaterials : .init()) }
    private func requirements(for materials: DemoChatMaterials) -> [DemoLabRequirement] {
        selectedPlan.requirements(settings: store.settings, hasModelKey: store.hasKey, hasSearchKey: store.hasSearchKey,
            hasDeepSeekSearchKey: store.hasDeepSeekSearchKey,
            pendingTexts: materials.resourceIDs.count, pendingImages: materials.imageIDs.count,
            pendingFiles: materials.fileResourceIDs.count)
    }
    var hasInput: Bool { !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (validationKind == nil && hasDraftAttachments) }
    var primaryTitle: String {
        if validation.isRunning { return validation.stopRequested ? "正在停止测试…" : "停止测试" }
        if search.isWorking { return "查看搜索进度" }
        if isLoadingPhoto { return "正在读取图片…" }
        if chat.isSending { return "查看运行中的任务" }
        if isApplying || chat.isPreparing { return "正在准备会话…" }
        if chat.isImporting { return "正在导入材料…" }
        if let requirement = requirements.first { return requirement.actionTitle }
        if !hasInput { return "输入任务后运行" }
        if validationKind == .calculator && !selectedPlan.groups.contains(.calculator) { return "勾选计算器" }
        if validationKind != nil { return "开始真实测试" }
        if chat.needsNewConversation { return "开始新对话并运行" }
        return "运行任务"
    }
    var canPerformPrimary: Bool {
        if validation.isRunning { return !validation.stopRequested }
        if search.isWorking { return true }
        return !isApplying && !isLoadingPhoto && (chat.isSending || (!chat.isBusy && (hasInput || !requirements.isEmpty)))
    }
    var selectionStatus: String { hasSelectionChanges ? "待运行时应用" : "已应用" }
    var latestResultTitle: String {
        if chat.isSending { return chat.statusTitle }
        if chat.needsNewConversation || chat.errorMessage != nil { return "查看上次未完成请求" }
        if chat.messages.last?.role == .assistant { return "查看最近的回答与工具统计" }
        return "前往对话"
    }

    func selectionChanged() {
        errorMessage = nil
        notice = nil
        if selectedPlan.groups.contains(.webSearch) {
            do {
                if try store.prepareSearchForToolSelection() {
                    notice = "已准备百度网页问答，无需搜索 Key；运行时才会请求联网确认。"
                }
            } catch { errorMessage = "未能准备搜索通道，请检查搜索设置。" }
        }
        store.stageToolPlan(selectedPlan)
    }
    func selectPreset(_ preset: BoneBuiltInToolPreset) {
        guard canEdit else { return }
        let groups = Set(preset.groups)
        for choice in choices { choice.isSelected = groups.contains(choice.group) }
        selectionChanged()
    }
    func clearSelection() {
        guard canEdit else { return }
        for choice in choices { choice.isSelected = false }
        selectionChanged()
    }
    func selectResources() {
        guard canEdit else { return }
        choices.first { $0.group == .resources }?.isSelected = true
        selectionChanged()
    }
    func openConfiguration(_ destination: Configuration) {
        guard canEdit else { return }
        configurationOpenedRevision = store.configurationRevision
        configuration = destination
    }
    func configurationSaved() {
        configuration = nil
        errorMessage = nil
        search.configurationChanged()
        if !store.settings.search.automaticEnabled {
            choices.first { $0.group == .webSearch }?.isSelected = false
            store.stageToolPlan(selectedPlan)
        }
        guard store.configurationRevision != configurationOpenedRevision else { return }
        isApplying = true
        transitionTask = Task {
            await chat.invalidateSavedArchive()
            isApplying = false
            transitionTask = nil
            notice = "配置已保存，任务草稿和工具选择已保留。新配置将在下次运行时使用。"
        }
    }
    func openTools() {
        configuration = nil
        selectedTab = .laboratory
        if labPath.last != .tools { labPath.append(.tools) }
    }
    func openSearch() {
        configuration = nil
        selectedTab = .laboratory
        if !labPath.contains(.search) { labPath.append(.search) }
    }
    func openSearch(for task: String) {
        let candidate = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isWorking, search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !candidate.isEmpty, candidate.utf8.count <= DemoSearchQuery.maximumBytes {
            search.query = candidate
        }
        openSearch()
    }
    func openBrowserSearch(using engine: DemoBrowserSearchEngine, for task: String) {
        guard canEdit else { return }
        search.selectBrowser(engine: engine)
        openSearch(for: task)
    }
    @discardableResult
    func enableBaiduForNextTask() -> Bool {
        guard canEdit else { return false }
        do {
            try store.selectBaiduWebSearchForTask()
            choices.first { $0.group == .webSearch }?.isSelected = true
            selectionChanged()
            notice = "已选择百度网页问答；点击发送后使用，搜索无需 DeepSeek 或 Brave Key。"
            return true
        } catch let error as DemoChatConfigurationError { errorMessage = error.message }
        catch { errorMessage = "未能启用百度网页问答，请检查搜索设置。" }
        return false
    }
    func searchBaiduAndAnswer() {
        guard canEdit, recoverFailedTask() else { return }
        guard !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "先输入要搜索的问题，再点击百度搜索并回答。"; return
        }
        if enableBaiduForNextTask() { performChatAction() }
    }
    func retryFailedTaskWithBaidu() {
        guard let task = retryableTask, enableBaiduForNextTask() else { return }
        requestRetry(task, source: .failed(task.id))
    }
    func retryFailedTask() {
        guard let task = retryableTask else { return }
        requestRetry(task, source: .failed(task.id))
    }
    func retryRetainedTask() {
        guard let task = retainedTask else { return }
        requestRetry(task, source: .retained(task.id))
    }
    private func requestRetry(_ task: DemoChatTaskBundle, source: TaskSource) {
        guard canEdit else { return }
        validationKind = nil; validationExpectedText = ""
        if !task.materials.resourceIDs.isEmpty || !task.materials.fileResourceIDs.isEmpty { selectResources() }
        let intent = RunIntent(text: task.text, plan: selectedPlan, revision: store.configurationRevision,
            validationKind: nil, expectedText: "", materials: task.materials, source: source)
        if let requirement = requirements(for: task.materials).first { resolve(requirement); return }
        requestRun(intent)
    }
    func setReplyLimit(_ tokens: Int) {
        guard canEdit else { return }
        do { try store.saveReplyLimit(tokens); notice = "回复长度上限已设为 \(tokens) Token，下次运行使用。" }
        catch let error as DemoChatConfigurationError { errorMessage = error.message }
        catch { errorMessage = "回复长度未能保存，请检查模型设置。" }
    }
    func useRecommendedModelCapacity() {
        guard canEdit else { return }
        do {
            try store.saveRecommendedModelCapacity()
            notice = "已保存模型建议的输出与窗口预算；未重发任务，自动摘要设置保持不变。"
        } catch let error as DemoChatConfigurationError { errorMessage = error.message }
        catch { errorMessage = "模型容量建议未能保存，请检查设置。" }
    }
    func removeDraftResource(id: String) {
        guard canEdit else { return }
        recoveredMaterials = recoveredMaterials.subtracting(.init(resourceIDs: [id]))
        chat.removeResource(id: id, retaining: (retainedTask?.materials ?? .init()).union(retryableTask?.materials ?? .init()))
    }
    /// 从待发送任务中移除统一文件资源附件。
    func removeDraftFileResource(id: String) {
        guard canEdit else { return }
        recoveredMaterials = recoveredMaterials.subtracting(.init(fileResourceIDs: [id]))
        chat.removeFileResource(id: id, retaining: (retainedTask?.materials ?? .init()).union(retryableTask?.materials ?? .init()))
    }
    func removeDraftImage(id: String) {
        guard canEdit else { return }
        recoveredMaterials = recoveredMaterials.subtracting(.init(imageIDs: [id]))
        chat.removeImage(id: id, retaining: (retainedTask?.materials ?? .init()).union(retryableTask?.materials ?? .init()))
    }
    func prepareNewConversation() {
        guard canEdit, recoverFailedTask() else { return }
        let preserving = protectedMaterials
        isApplying = true
        transitionTask = Task {
            _ = await chat.resetForRun(preservingPendingAttachments: true, retaining: preserving)
            isApplying = false; transitionTask = nil
        }
    }
    func returnToTask() { selectedTab = .laboratory; labPath = [] }
    func useSearchMaterial(_ material: DemoSearchSelection) -> Bool {
        guard canEdit else { errorMessage = "当前任务运行中，请结束后再加入材料。"; return false }
        let prefix = taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "请结合以下材料回答，并注明来源。" : taskText
        let combined = prefix + "\n\n" + material.taskMaterial
        guard combined.utf8.count <= DemoLiveChatSession.maximumUserMessageBytes else {
            errorMessage = "加入后任务过长，请缩短草稿或少选一些文字。"; return false
        }
        taskText = combined
        validationKind = nil; validationExpectedText = ""
        errorMessage = nil
        notice = "搜索材料已加入草稿，点击运行后才会发送给模型。"
        return true
    }

    func openChat() { selectedTab = .chat }
    func resolve(_ requirement: DemoLabRequirement) {
        switch requirement.kind {
        case .model, .vision: openConfiguration(.model)
        case .webHosts, .searchKey: openConfiguration(.network)
        case .resources: selectResources()
        }
    }

    func requestValidation(_ kind: DemoValidationKind) {
        guard canEdit else { return }
        if !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && taskText != kind.task {
            pendingValidationKind = kind
            confirmsValidationReplacement = true
        } else { applyValidation(kind) }
    }
    func confirmValidationReplacement() {
        if let pendingValidationKind { applyValidation(pendingValidationKind) }
        cancelValidationReplacement()
    }
    func cancelValidationReplacement() {
        pendingValidationKind = nil
        confirmsValidationReplacement = false
    }
    private func applyValidation(_ kind: DemoValidationKind) {
        validationKind = kind
        validationExpectedText = ""
        taskText = kind.task
        if kind == .calculator {
            choices.first { $0.group == .calculator }?.isSelected = true
            selectionChanged()
        }
    }
    func useOrdinaryTask() {
        guard canEdit else { return }
        validationKind = nil
        validationExpectedText = ""
    }
    func validationFinished() {
        guard !validation.isRunning, validation.frozenRequest != nil,
              selectedTab == .laboratory, labPath.isEmpty else { return }
        labPath.append(.validationResult)
    }
    func requestExample(_ group: BoneBuiltInToolGroup) {
        guard canEdit else { return }
        let example = DemoToolUsage.guide(for: group).example
        if !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && taskText != example {
            pendingExample = (example, group)
            confirmsExampleReplacement = true
        } else { applyExample(example, group: group) }
    }
    func confirmExampleReplacement() {
        if let pendingExample { applyExample(pendingExample.text, group: pendingExample.group) }
        pendingExample = nil
        confirmsExampleReplacement = false
        configuration = nil
    }
    func cancelExampleReplacement() { pendingExample = nil; confirmsExampleReplacement = false }
    private func applyExample(_ text: String, group: BoneBuiltInToolGroup) {
        choices.first { $0.group == group }?.isSelected = true
        validationKind = nil
        validationExpectedText = ""
        selectionChanged()
        taskText = text
        configuration = nil
    }

    func performChatAction() {
        guard !validation.isRunning && !search.isWorking else { return }
        validationKind = nil
        performPrimaryAction()
    }

    func performPrimaryAction() {
        if search.isWorking { openSearch(); return }
        if validation.isRunning { validation.stop(interactions: chat.interactions); return }
        if chat.isSending { openChat(); return }
        guard canEdit else { return }
        errorMessage = nil
        if validationKind == nil && chat.needsNewConversation && !recoverFailedTask() { return }
        if let requirement = requirements.first { resolve(requirement); return }
        if validationKind == .calculator && !selectedPlan.groups.contains(.calculator) {
            choices.first { $0.group == .calculator }?.isSelected = true
            selectionChanged()
            return
        }
        guard hasInput else { return }
        let text = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= DemoLiveChatSession.maximumUserMessageBytes else {
            errorMessage = "任务超过 16 KiB，请缩短后运行。"; return
        }
        let intent = RunIntent(text: text, plan: selectedPlan, revision: store.configurationRevision,
                               validationKind: validationKind, expectedText: validationExpectedText,
                               materials: validationKind == nil ? draftMaterials : .init(), source: .composer)
        requestRun(intent)
    }
    private func requestRun(_ intent: RunIntent) {
        let target = intent.plan.applying(to: store.settings)
        if intent.validationKind == nil && !chat.messages.isEmpty && chat.requiresConfigurationReset(settings: target, revision: store.configurationRevision) {
            pendingRun = intent
            confirmsNewRun = true
        } else { execute(intent) }
    }
    func confirmNewRun() {
        confirmsNewRun = false
        guard let pendingRun else { return }
        self.pendingRun = nil
        execute(pendingRun)
    }
    func cancelNewRun() { pendingRun = nil; confirmsNewRun = false }
    private func sourceMatches(_ intent: RunIntent) -> Bool {
        switch intent.source {
        case .composer:
            return intent.text == taskText.trimmingCharacters(in: .whitespacesAndNewlines) &&
                intent.materials == (intent.validationKind == nil ? draftMaterials : .init()) &&
                intent.validationKind == validationKind && intent.expectedText == validationExpectedText
        case .failed(let id): return retryableTask?.id == id && retryableTask?.materials == intent.materials
        case .retained(let id): return retainedTask?.id == id && retainedTask?.materials == intent.materials
        }
    }
    private func execute(_ intent: RunIntent) {
        guard canEdit, intent.plan == selectedPlan, intent.revision == store.configurationRevision,
              sourceMatches(intent), requirements(for: intent.materials).isEmpty else {
            errorMessage = "任务或配置刚发生变化，请检查后重新运行。"; return
        }
        if let kind = intent.validationKind {
            do {
                try store.applyToolPlan(intent.plan)
                validation.run(.init(kind: kind, settings: store.settings, input: intent.text, expectedText: intent.expectedText),
                               store: store, interactions: chat.interactions,
                               onFinished: { [weak self] in self?.validationFinished() })
            } catch let error as DemoChatConfigurationError { errorMessage = error.message }
            catch { errorMessage = "设置尚未保存，请检查后重试。" }
            return
        }
        let preserving = protectedMaterials.union(intent.materials)
        // Retrying the retained slot frees it only after send acceptance. Move a
        // different failed task there so resetting the Conversation cannot erase it.
        let displacedTask: DemoChatTaskBundle?
        if case .retained(let id) = intent.source, retryableTask?.id != id { displacedTask = retryableTask }
        else { displacedTask = nil }
        isApplying = true
        transitionTask = Task {
            var accepted = false
            defer {
                if !accepted, case .failed = intent.source {
                    chat.retainRejectedTask(.init(text: intent.text, materials: intent.materials))
                }
                if !accepted, let displacedTask { chat.retainRejectedTask(displacedTask) }
                isApplying = false; transitionTask = nil
            }
            do {
                try store.applyToolPlan(intent.plan)
                if chat.requiresConfigurationReset(settings: store.settings, revision: store.configurationRevision) {
                    guard await chat.resetForRun(preservingPendingAttachments: true, retaining: preserving) else {
                        errorMessage = chat.errorMessage ?? "未能准备新会话，请重试。"; return
                    }
                }
                selectedTab = .chat
                if chat.send(intent.text, store: store, materials: intent.materials,
                             consumesPendingAttachments: intent.source == .composer) {
                    accepted = true
                    if intent.source == .composer {
                        if taskText.trimmingCharacters(in: .whitespacesAndNewlines) == intent.text { taskText = "" }
                        recoveredMaterials = recoveredMaterials.subtracting(intent.materials)
                    }
                    if case .retained(let id) = intent.source, retainedTask?.id == id { retainedTask = displacedTask }
                    notice = nil
                } else { errorMessage = chat.errorMessage ?? "请求尚未发出，请检查当前状态。" }
            } catch let error as DemoChatConfigurationError { errorMessage = error.message }
            catch let error as LiveChatKeychainError { errorMessage = error.message }
            catch { errorMessage = "工具选择未能应用，请检查配置后重试。" }
        }
    }
    func recoverRejectedInputIfNeeded() {
        if let task = chat.rejectedTask, restoreUnsent(task) { chat.clearRejectedTask(id: task.id) }
    }
    func clearTaskDraft() {
        taskText = ""; retainedTask = nil; recoveredMaterials = .init()
        validationKind = nil; validationExpectedText = ""
    }
    @discardableResult
    func recoverFailedTask() -> Bool {
        guard canEdit else { return false }
        guard let task = retryableTask else { return true }
        guard restoreUnsent(task) else { return false }
        notice = "原问题与关联材料已保留，已有草稿未被替换。点击发送或重试后才会运行。"
        return true
    }
    @discardableResult
    private func restoreUnsent(_ task: DemoChatTaskBundle) -> Bool {
        let draft = DemoChatTaskBundle(text: taskText.trimmingCharacters(in: .whitespacesAndNewlines), materials: draftMaterials)
        switch DemoTaskRecovery.destination(for: task, draft: draft, retained: retainedTask) {
        case .draft:
            taskText = task.text; recoveredMaterials = recoveredMaterials.union(task.materials)
        case .retained: retainedTask = task
        case .alreadyPresent: break
        case .full:
            errorMessage = "输入框和保留任务中已有其他草稿。请先复制保存其中一条；失败任务及其材料仍保留。"
            return false
        }
        return true
    }
    func useResource(name: String, text: String) async -> Bool {
        guard canEdit else { return false }
        let originTab = selectedTab
        let originPath = labPath
        let originText = taskText
        selectResources()
        guard await chat.importTextContent(name: name, text: text) else { return false }
        validationKind = nil
        validationExpectedText = ""
        if taskText == originText && taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            taskText = DemoToolUsage.guide(for: .resources).example
        }
        if selectedTab == originTab && labPath == originPath && labPath.last == .textResource {
            labPath.removeLast()
        }
        notice = "材料已加入待发送列表。运行后才会发送预览，原文按需读取。"
        return true
    }
}
