import Foundation
import Observation
import BoneAgentKit
import BoneAgentTools

typealias LiveChatMessage = DemoChatMessageRecord

@Observable
@MainActor
final class LiveChatModel {
    private(set) var messages: [LiveChatMessage] = []
    private(set) var isSending = false
    private(set) var isPreparing = false
    private(set) var isImporting = false
    private(set) var errorMessage: String?
    private(set) var toolFailure: DemoToolFailure?
    private(set) var failureDiagnostic: DemoRunFailureDiagnostic?
    private(set) var failureHistory: [DemoRunFailureDiagnostic] = []
    private(set) var diagnosticLogError: String?
    private(set) var failedTask: DemoChatTaskBundle?
    var failedTaskText: String? { failedTask?.text }
    private(set) var rejectedTask: DemoChatTaskBundle?
    private(set) var failureHadAutomaticSearch = false
    private(set) var notice: String?
    private(set) var needsNewConversation = false
    private(set) var partialReply = ""
    private(set) var unfinishedReply: String?
    private(set) var conversationProvider: DemoChatProvider?
    private(set) var currentStatus: BoneAgentStatus?
    private(set) var tokenSnapshot: BoneAgentTokenSnapshot?
    private(set) var statistics = BoneAgentStatistics(snapshots: [])
    private(set) var contextCompactions: [BoneContextCompactionReceipt] = []
    private(set) var contextFailure: BoneContextFailureDiagnostic?
    private(set) var images: [DemoPreparedChatImage] = []
    private(set) var resources: [DemoImportedTextResource] = []
    private(set) var fileResources: [DemoImportedFileResource] = []
    private(set) var pendingImageIDs: [String] = []
    private(set) var pendingResourceIDs: [String] = []
    /// 待发送统一文件资源身份，与旧文本资源分开维护。
    private(set) var pendingFileResourceIDs: [String] = []
    let isUITesting: Bool
    let interactions = LiveToolInteractionModel()
    let browserSearch: LiveBrowserSearchModel
    var isBusy: Bool { isSending || isPreparing || isImporting }
    var hasAttachments: Bool { !pendingImageIDs.isEmpty || !pendingResourceIDs.isEmpty || !pendingFileResourceIDs.isEmpty }
    var pendingImages: [DemoPreparedChatImage] { images.filter { pendingImageIDs.contains($0.id) } }
    var pendingResources: [DemoImportedTextResource] { resources.filter { pendingResourceIDs.contains($0.id) } }
    /// 返回待发送的统一文件资源。
    var pendingFileResources: [DemoImportedFileResource] { fileResources.filter { pendingFileResourceIDs.contains($0.id) } }
    var pendingMaterials: DemoChatMaterials {
        .init(imageIDs: pendingImageIDs, resourceIDs: pendingResourceIDs, fileResourceIDs: pendingFileResourceIDs)
    }
    var conversationMaterials: DemoChatMaterials {
        .init(imageIDs: messages.flatMap(\.imageIDs), resourceIDs: messages.flatMap(\.resourceIDs),
              fileResourceIDs: messages.flatMap(\.fileResourceIDs))
    }

    private var session: DemoLiveChatSession?
    private var imageStore = DemoChatImageStore()
    private var resourceStore = DemoTextResourceStore()
    private var fileResourceStore: DemoFileResourceStore
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var hasPrepared = false
    private var sessionBindingID: String?
    private var sessionConfigurationRevision: UInt64?
    private var rejectedInput: String?
    private let archives: DemoConversationArchiveStore
    private let failureLogs: DemoFailureLogStore

    init(isUITesting: Bool = false) {
        self.isUITesting = isUITesting
        browserSearch = LiveBrowserSearchModel(isUITesting: isUITesting)
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        fileResourceStore = DemoFileResourceStore(directory: root.appendingPathComponent(
            isUITesting ? "AgentLabFilesUITests" : "AgentLabFiles", isDirectory: true
        ))
        archives = DemoConversationArchiveStore(directory: root.appendingPathComponent(
            isUITesting ? "AgentLabConversationsUITests" : "AgentLabConversations", isDirectory: true
        ))
        failureLogs = DemoFailureLogStore(directory: root.appendingPathComponent(
            isUITesting ? "AgentLabDiagnosticsUITests" : "AgentLabDiagnostics", isDirectory: true
        ))
    }

    /// Restores locally. This path never dispatches inference or resumes an interrupted request.
    func prepare(store: LiveChatSettingsStore) async {
        guard !hasPrepared, !isBusy else { return }
        hasPrepared = true
        isPreparing = true
        defer { isPreparing = false }
        // 保存开关在设置提交时也检查，防止导入后重新开启而静默漏存。
        store.validateConversationPersistence = { [weak self] enabled in
            guard let self else { return }
            try self.validatePersistence(enabled: enabled)
        }
        let settings = store.settings
        do { failureHistory = try await failureLogs.records() }
        catch { diagnosticLogError = "本机诊断记录暂时无法读取。" }
        do {
            if isUITesting && !ProcessInfo.processInfo.arguments.contains("--preserve-ui-test-state") {
                try await archives.clear()
            }
            guard settings.preservesConversation else {
                try await archives.clear()
                return
            }
            guard let saved = try await archives.load(bindingID: settings.conversationBindingID) else { return }
            let restoredImages = try DemoChatImageStore(privateState: saved.imageState)
            let restoredResources = try DemoTextResourceStore(privateState: saved.textResourceState)
            let restoredFiles = try DemoFileResourceStore(privateState: saved.fileResourceState, directory: fileResourceDirectory())
            let imageEntries = await restoredImages.entries()
            let resourceEntries = await restoredResources.entries()
            let restoredFileEntries = await restoredFiles.entries()
            guard saved.messages.allSatisfy({ message in
                message.imageIDs.allSatisfy { id in imageEntries.contains { $0.id == id } } &&
                message.resourceIDs.allSatisfy { id in resourceEntries.contains { $0.id == id } } &&
                message.fileResourceIDs.allSatisfy { id in restoredFileEntries.contains { $0.id == id } }
            }) else { throw DemoConversationStorageError.invalidArchive }
            imageStore = restoredImages
            resourceStore = restoredResources
            fileResourceStore = restoredFiles
            images = imageEntries
            resources = resourceEntries
            fileResources = restoredFileEntries
            messages = saved.messages
            conversationProvider = settings.provider
            if saved.requestInFlight {
                needsNewConversation = true
                notice = "上次请求未确认完成。已恢复此前完成的历史，请开始新对话后继续。"
                return
            }
            guard store.hasKey else {
                needsNewConversation = true
                notice = "已载入本机历史。当前连接缺少 Key，请设置模型后开始新对话。"
                return
            }
            session = try await makeSession(settings: settings, key: store.key(for: settings),
                searchAPIKey: settings.enablesWebSearch ? store.automaticSearchKey(for: settings) : "", restoredState: saved.sdkState,
                restoredResourceIDs: Set(saved.messages.flatMap(\.resourceIDs)),
                restoredFileResourceIDs: Set(saved.messages.flatMap(\.fileResourceIDs)))
            recordSessionConfiguration(settings: settings, revision: store.configurationRevision)
            if let session { statistics = await session.statistics() }
            notice = "已恢复本机对话。历史时延和用量未持久化，统计从本次打开后开始。"
        } catch {
            errorMessage = Self.safeMessage(error)
            needsNewConversation = true
        }
    }

    @discardableResult
    func send(_ text: String, store: LiveChatSettingsStore, materials: DemoChatMaterials? = nil,
              consumesPendingAttachments: Bool = true) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = materials ?? pendingMaterials
        guard hasPrepared, !isBusy, !needsNewConversation, !text.isEmpty || !selected.isEmpty else { return false }
        guard selected.imageIDs.allSatisfy({ id in images.contains { $0.id == id } }),
              selected.resourceIDs.allSatisfy({ id in resources.contains { $0.id == id } }),
              selected.fileResourceIDs.allSatisfy({ id in fileResources.contains { $0.id == id } }) else {
            errorMessage = "任务附件已不可用，请重新选择。"; return false
        }
        guard text.utf8.count <= DemoLiveChatSession.maximumUserMessageBytes else {
            errorMessage = "消息过长，请缩短到 16 KiB 以内。"
            return false
        }
        let settings: DemoLiveChatSettings
        let key: String
        let searchAPIKey: String
        do {
            settings = try store.settings.validated()
            try validatePersistence(enabled: settings.preservesConversation)
            key = try store.key(for: settings)
            _ = try settings.providerConfiguration(apiKey: key)
            searchAPIKey = settings.enablesWebSearch ? try store.automaticSearchKey(for: settings) : ""
            guard !requiresConfigurationReset(settings: settings, revision: store.configurationRevision) else {
                errorMessage = "配置已变更，请在实验室运行或开始新对话后继续。"
                return false
            }
        } catch {
            errorMessage = Self.safeMessage(error)
            return false
        }
        let configurationRevision = store.configurationRevision
        rejectedInput = nil; rejectedTask = nil
        errorMessage = nil
        toolFailure = nil
        failureDiagnostic = nil
        failedTask = nil
        unfinishedReply = nil
        failureHadAutomaticSearch = settings.enablesWebSearch
        notice = nil
        browserSearch.clear()
        partialReply = ""
        currentStatus = nil
        tokenSnapshot = nil
        contextCompactions = []; contextFailure = nil
        isSending = true
        let imageIDs = selected.imageIDs
        let resourceIDs = selected.resourceIDs
        let fileResourceIDs = selected.fileResourceIDs
        let attachedResources = resources.filter { resourceIDs.contains($0.id) }
        let attachedFileResources = fileResources.filter { fileResourceIDs.contains($0.id) }
        task = Task {
            defer { isSending = false; task = nil }
            var dispatched = false
            var markerWritten = false
            do {
                if session == nil {
                    session = try await makeSession(settings: settings, key: key, searchAPIKey: searchAPIKey)
                    recordSessionConfiguration(settings: settings, revision: configurationRevision)
                }
                guard let session else { throw DemoLiveChatFailure.unknown }
                let inputs = try await imageStore.inputs(for: imageIDs)
                try Task.checkCancellation()
                // The marker contains only previously committed rows and an idle SDK state.
                if settings.preservesConversation {
                    try await saveArchive(settings: settings, session: session, inFlight: true)
                    markerWritten = true
                }
                try Task.checkCancellation()
                messages.append(.init(role: .user, text: text, imageIDs: imageIDs,
                                      resourceIDs: resourceIDs, fileResourceIDs: fileResourceIDs))
                if consumesPendingAttachments {
                    pendingImageIDs.removeAll { imageIDs.contains($0) }
                    pendingResourceIDs.removeAll { resourceIDs.contains($0) }
                    pendingFileResourceIDs.removeAll { fileResourceIDs.contains($0) }
                }
                dispatched = true
                let reply = try await session.send(text, images: inputs, resources: attachedResources, fileResources: attachedFileResources)
                partialReply = ""
                messages.append(.init(role: .assistant, text: reply.text,
                                      detail: "\(reply.steps) 次推理 · \(reply.toolCalls) 次工具调用"))
                statistics = await session.statistics()
                if settings.preservesConversation {
                    do { try await saveArchive(settings: settings, session: session, inFlight: false) }
                    catch {
                        notice = "回复已完成，但本机保存未完成。当前回复可继续查看；重新打开 App 时可能只恢复此前历史。"
                    }
                }
            } catch {
                // Draft deltas never become a committed assistant reply on failure.
                let unfinished = partialReply
                partialReply = ""
                if let session {
                    statistics = await session.statistics()
                    toolFailure = await session.toolFailureDiagnostic()
                    failureDiagnostic = await session.failureDiagnostic()
                }
                if failureDiagnostic?.code == .outputTruncated && !unfinished.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unfinishedReply = unfinished
                }
                errorMessage = toolFailure?.title ?? (error as? DemoLiveChatFailure == .limitReached
                    ? failureDiagnostic?.message : nil) ?? Self.safeMessage(error)
                if let failureDiagnostic {
                    failureHistory.append(failureDiagnostic)
                    failureHistory = Array(failureHistory.suffix(DemoFailureLogStore.maximumRecords))
                    do {
                        try await failureLogs.record(failureDiagnostic)
                        diagnosticLogError = nil
                    } catch { diagnosticLogError = "诊断未能保存到本机，可在当前页面分享诊断。" }
                }
                if dispatched { failedTask = .init(text: text, materials: conversationMaterials) }
                needsNewConversation = dispatched || markerWritten
                if !dispatched {
                    rejectedInput = text
                    rejectedTask = .init(text: text, materials: selected)
                }
                // Before dispatch the idle session is still valid, including its prior history.
            }
        }
        return true
    }

    func stop() { interactions.cancel(); browserSearch.cancel(); task?.cancel() }

    func requiresConfigurationReset(settings: DemoLiveChatSettings, revision: UInt64) -> Bool {
        needsNewConversation || (session != nil &&
            (sessionBindingID != settings.conversationBindingID || sessionConfigurationRevision != revision))
    }

    func takeRejectedInput() -> String? {
        defer { rejectedInput = nil }
        return rejectedInput
    }
    func clearRejectedTask(id: UUID) {
        if rejectedTask?.id == id { rejectedTask = nil; rejectedInput = nil }
    }
    func retainRejectedTask(_ task: DemoChatTaskBundle) {
        guard !isBusy, rejectedTask == nil else { return }
        rejectedTask = task
    }

    /// 读取旧文本资源的本地分页预览。
    /// - Parameters:
    ///   - resource: 已导入文本资源。
    ///   - offset: UTF-8 字节偏移。
    /// - Returns: 有界文本页。
    func readLocalTextPage(_ resource: DemoImportedTextResource, offset: Int) async throws -> BoneToolTextResourcePage {
        try await resourceStore.readText(.init(reference: resource.preview.reference, offset: offset, maximumBytes: 16_384))
    }

    /// 检查统一文件资源，供本机预览读取元数据。
    func inspectFileResource(_ resource: DemoImportedFileResource) async throws -> BoneFileResourceInspection {
        try await fileResourceStore.inspect(resource.reference)
    }

    /// 探测统一文件资源格式和保护状态。
    func detectFileResourceFormat(_ resource: DemoImportedFileResource) async throws -> BoneFileResourceFormatInspection {
        try await fileResourceStore.detectFormat(resource.reference)
    }

    /// 读取统一文件资源的有界窗口。
    func readFileResourceWindow(_ request: BoneFileResourceWindowRequest, password: String? = nil) async throws -> BoneFileResourceWindowResult {
        try await fileResourceStore.readWindow(request, password: password)
    }

    /// 读取 Office 结构化内容。
    func readFileResourceOffice(_ request: BoneFileResourceOfficeStructureRequest) async throws -> BoneFileResourceOfficeStructureResult {
        try await fileResourceStore.readOffice(request)
    }

    /// 列出归档条目。
    func listFileResourceEntries(_ resource: DemoImportedFileResource) async throws -> [BoneFileArchiveEntry] {
        try await fileResourceStore.listEntries(resource.reference)
    }

    /// 读取统一文件资源的原始字节窗口。
    /// - Parameter request: 绑定资源引用和有界字节范围的请求。
    /// - Returns: 当前范围的二进制页和下一页游标。
    func readFileResourceBytes(_ request: BoneFileResourceByteReadRequest) async throws -> BoneFileResourceBytePage {
        try await fileResourceStore.readBytes(request)
    }

    /// 读取 PDF 页面布局，供本机预览按页还原文本和几何信息。
    /// - Parameters:
    ///   - request: 绑定 PDF 资源、页范围和结果预算的请求。
    ///   - password: 当前调用临时使用的 PDF 密码，不会写入会话状态。
    /// - Returns: 有界 PDF 页面布局和下一页游标。
    func readFileResourcePDFLayout(_ request: BoneFileResourcePDFLayoutRequest, password: String? = nil) async throws -> BoneFileResourcePDFLayoutResult {
        try await fileResourceStore.readPDFLayout(request, password: password)
    }

    /// 对 PDF 页面执行有界 OCR，供本机预览查看扫描文档文字。
    /// - Parameters:
    ///   - request: 绑定 PDF 资源、页范围、语言和预算的请求。
    ///   - password: 当前调用临时使用的 PDF 密码，不会写入会话状态。
    /// - Returns: 有界 OCR 页面结果和下一页游标。
    func recognizeFileResourcePDF(_ request: BoneFileResourceOCRRequest, password: String? = nil) async throws -> BoneFileResourceOCRResult {
        try await fileResourceStore.ocr(request, password: password)
    }

    func startNewConversation() {
        guard !isBusy else { return }
        isPreparing = true
        task = Task {
            defer { isPreparing = false; task = nil }
            _ = await performReset(preservingPendingAttachments: false)
        }
    }

    func resetForRun(preservingPendingAttachments: Bool, retaining materials: DemoChatMaterials = .init()) async -> Bool {
        guard !isBusy else { return false }
        isPreparing = true
        defer { isPreparing = false }
        return await performReset(preservingPendingAttachments: preservingPendingAttachments, retaining: materials)
    }

    func invalidateSavedArchive() async {
        guard !isBusy else { return }
        isPreparing = true
        defer { isPreparing = false }
        do { try await archives.clear() }
        catch { errorMessage = Self.safeMessage(error); needsNewConversation = true }
    }

    private func performReset(preservingPendingAttachments: Bool, retaining materials: DemoChatMaterials = .init()) async -> Bool {
        hasPrepared = true
        browserSearch.clear()
        generation = UUID()
        do {
            try await archives.clear()
            if preservingPendingAttachments {
                let imageIDs = Set(pendingImageIDs + materials.imageIDs)
                let resourceIDs = Set(pendingResourceIDs + materials.resourceIDs)
                let fileResourceIDs = Set(pendingFileResourceIDs + materials.fileResourceIDs)
                for image in images where !imageIDs.contains(image.id) { await imageStore.remove(id: image.id) }
                for resource in resources where !resourceIDs.contains(resource.id) { await resourceStore.remove(id: resource.id) }
                for resource in fileResources where !fileResourceIDs.contains(resource.id) { try? await fileResourceStore.remove(id: resource.id) }
                images = await imageStore.entries()
                resources = await resourceStore.entries()
                fileResources = await fileResourceStore.entries()
            } else {
                imageStore = DemoChatImageStore(); resourceStore = DemoTextResourceStore()
                fileResourceStore = DemoFileResourceStore(directory: fileResourceDirectory())
                images = []; resources = []; fileResources = []
                pendingImageIDs = []; pendingResourceIDs = []; pendingFileResourceIDs = []
            }
            messages = []; session = nil; sessionBindingID = nil; sessionConfigurationRevision = nil
            conversationProvider = nil; rejectedInput = nil; rejectedTask = nil; partialReply = ""
            currentStatus = nil; tokenSnapshot = nil; statistics = .init(snapshots: [])
            contextCompactions = []; contextFailure = nil
            errorMessage = nil; notice = nil; needsNewConversation = false
            toolFailure = nil; failedTask = nil; failureHadAutomaticSearch = false
            unfinishedReply = nil
            failureDiagnostic = nil
            return true
        } catch {
            errorMessage = Self.safeMessage(error); needsNewConversation = true
            return false
        }
    }

    private func recordSessionConfiguration(settings: DemoLiveChatSettings, revision: UInt64) {
        sessionBindingID = settings.conversationBindingID
        sessionConfigurationRevision = revision
        conversationProvider = settings.provider
    }

    func importTextContent(name: String, text: String) async -> Bool {
        guard !isBusy else { return false }
        isImporting = true
        defer { isImporting = false }
        do {
            let resource = try await resourceStore.add(name: name, text: text)
            resources = await resourceStore.entries()
            pendingResourceIDs.append(resource.id)
            errorMessage = nil
            return true
        } catch { errorMessage = Self.safeMessage(error); return false }
    }

    func importImage(data: Data, settings: DemoLiveChatSettings) async {
        guard !isBusy else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            guard settings.visionPolicy != .disabled else { throw DemoVisionError.disabled }
            try settings.visionPolicy.validate(settings: settings)
            let image = try await imageStore.add(data: data)
            images = await imageStore.entries()
            pendingImageIDs.append(image.id)
            errorMessage = nil
        } catch { errorMessage = Self.safeMessage(error) }
    }

    /// 导入任意文件，使用 SDK Store 生成跨进程快照并加入待发送附件。
    /// - Parameters:
    ///   - url: 系统文件选择器返回的授权 URL。
    ///   - settings: 当前会话设置，用于确认资源工具已启用。
    func importFile(url: URL, settings: DemoLiveChatSettings) async {
        guard !isBusy, settings.enablesTextResources else {
            if !settings.enablesTextResources { errorMessage = "请先启用文件资源工具。" }
            return
        }
        isImporting = true; defer { isImporting = false }
        do {
            // security scope 覆盖任意文件快照导入全过程，避免文件选择器权限在异步读取前失效。
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let resource = try await fileResourceStore.add(importing: url)
            fileResources = await fileResourceStore.entries()
            pendingFileResourceIDs.append(resource.id)
            notice = "已导入文件：\(resource.name)"
        } catch { errorMessage = Self.safeMessage(error) }
    }

    func importText(url: URL, settings: DemoLiveChatSettings) async {
        guard !isBusy, settings.enablesTextResources else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            // security scope 覆盖快照导入全过程；I/O 在资源 actor 执行，不占主线程。
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let resource = try await resourceStore.add(importing: url, preservesConversation: settings.preservesConversation)
            resources = await resourceStore.entries()
            pendingResourceIDs.append(resource.id)
            errorMessage = nil
        } catch { errorMessage = Self.safeMessage(error) }
    }

    func reportAttachmentError() { errorMessage = "无法读取所选附件，请重新选择。" }

    func removeImage(id: String, retaining materials: DemoChatMaterials = .init()) {
        guard !isBusy, images.contains(where: { $0.id == id }) else { return }
        pendingImageIDs.removeAll { $0 == id }
        guard !materials.imageIDs.contains(id), !messages.contains(where: { $0.imageIDs.contains(id) }) else { return }
        isImporting = true
        task = Task {
            await imageStore.remove(id: id)
            images = await imageStore.entries()
            isImporting = false
            task = nil
        }
    }

    /// 删除未被消息或保留任务引用的旧文本资源。
    func removeResource(id: String, retaining materials: DemoChatMaterials = .init()) {
        guard !isBusy, resources.contains(where: { $0.id == id }) else { return }
        pendingResourceIDs.removeAll { $0 == id }
        guard !materials.resourceIDs.contains(id), !messages.contains(where: { $0.resourceIDs.contains(id) }) else { return }
        isImporting = true
        task = Task {
            await resourceStore.remove(id: id)
            resources = await resourceStore.entries()
            isImporting = false
            task = nil
        }
    }


    /// 删除未被消息或保留任务引用的统一文件资源，并回收其快照。
    func removeFileResource(id: String, retaining materials: DemoChatMaterials = .init()) {
        guard !isBusy, fileResources.contains(where: { $0.id == id }) else { return }
        pendingFileResourceIDs.removeAll { $0 == id }
        guard !materials.fileResourceIDs.contains(id), !messages.contains(where: { $0.fileResourceIDs.contains(id) }) else { return }
        isImporting = true
        task = Task {
            try? await fileResourceStore.remove(id: id)
            fileResources = await fileResourceStore.entries()
            isImporting = false
            task = nil
        }
    }
    private func makeSession(settings: DemoLiveChatSettings, key: String,
                             searchAPIKey: String = "", restoredState: Data? = nil,
                             restoredResourceIDs: Set<String> = [],
                             restoredFileResourceIDs: Set<String> = []) async throws -> DemoLiveChatSession {
        try await resourceStore.validatePersistence(preservesConversation: settings.preservesConversation)
        let currentGeneration = generation
        let observer: DemoLiveChatObserver = { [weak self] update in
            await self?.receive(update, generation: currentGeneration)
        }
        let configuration = try await imageStore.configuration(settings: settings)
        let transport: any BoneInferenceHTTPTransport = isUITesting
            ? LiveChatUITestTransport(provider: settings.provider)
            : BoneInferenceURLSessionTransport()
        return try await DemoLiveChatSession.make(settings: settings, apiKey: key, transport: transport,
            observer: observer, textResources: resourceStore, fileResources: fileResourceStore, imageInputConfiguration: configuration,
            bindingID: settings.conversationBindingID, restoredState: restoredState,
            toolInteractions: interactions.handlers, searchAPIKey: searchAPIKey,
            webTransport: isUITesting ? LiveToolsUITestWebTransport() : nil,
            browserSearch: browserSearch.handler,
            restoredResourceReferences: resources.filter { restoredResourceIDs.contains($0.id) }.map { $0.preview.reference },
            restoredFileResourceReferences: fileResources.filter { restoredFileResourceIDs.contains($0.id) }.map(\.reference))
    }

    private func receive(_ update: DemoLiveChatUpdate, generation: UUID) {
        guard generation == self.generation, isSending else { return }
        switch update {
        case .inferenceStarted: partialReply = ""
        case .textDelta(let text): partialReply += text
        case .status(let status): currentStatus = status; tokenSnapshot = status.tokens
        case .tokens(let snapshot): tokenSnapshot = snapshot
        case .contextCompacted(let receipt): contextCompactions = Array((contextCompactions + [receipt]).suffix(8))
        case .contextFailure(let failure): contextFailure = failure
        }
    }

    private func saveArchive(settings: DemoLiveChatSettings, session: DemoLiveChatSession,
                             inFlight: Bool) async throws {
        try await resourceStore.validatePersistence(preservesConversation: true)
        let sdk = try await session.exportPrivateState()
        let text = try await resourceStore.exportPrivateState()
        let image = try await imageStore.exportPrivateState()
        let files = try await fileResourceStore.exportPrivateState()
        try await archives.save(.init(bindingID: settings.conversationBindingID, sdkState: sdk,
            textResourceState: text, imageState: image, fileResourceState: files, messages: messages, requestInFlight: inFlight))
    }

    /// 设置提交与发送前统一检查；导入过程中也阻止开启保存，避免设置竞态。
    func validatePersistence(enabled: Bool) throws {
        guard !enabled || (!isImporting && !resources.contains(where: \.isDiskBacked)) else {
            throw DemoTextResourceStoreError.largeResourceCannotBeSaved
        }
    }

    /// 返回 Demo 文件快照目录，保证恢复和正常运行使用同一位置。
    private func fileResourceDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent(isUITesting ? "AgentLabFilesUITests" : "AgentLabFiles", isDirectory: true)
    }

    private static func safeMessage(_ error: Error) -> String {
        if let error = error as? DemoChatConfigurationError { return error.message }
        if let error = error as? LiveChatKeychainError { return error.message }
        if let error = error as? DemoLiveChatFailure { return error.message }
        if let error = error as? DemoConversationStorageError { return error.message }
        if let error = error as? DemoVisionError { return error.message }
        if let error = error as? BoneFileResourceError {
            switch error {
            case .capacityExceeded, .archiveLimitExceeded: return "文件或展开结果超过读取上限。"
            case .invalidEncoding, .unsupportedEncoding: return "文件编码暂不支持或无法确认。"
            case .unsupportedFormat: return "文件格式暂不支持结构化解析。"
            case .passwordRequired: return "该 PDF 需要密码，工具会在本次读取时请求密码。"
            case .invalidPassword: return "PDF 密码错误，请重新输入。"
            case .protectedContent: return "文件内容受保护，当前操作无法读取。"
            case .accessDenied, .expired, .referenceMismatch, .unavailable: return "文件引用已失效或当前不可读取，请重新导入。"
            default: return "文件读取失败，请重新选择附件。"
            }
        }
        if let error = error as? BoneDiskTextResourceError {
            switch error {
            case .capacityExceeded: return "文件超过 100 MiB 上限。"
            case .invalidEncoding: return "请选择有效的 UTF-8 文本文件。"
            case .notRegularFile: return "只能导入普通文本文件。"
            case .unavailable: return "文件不可读取，请重新选择。"
            }
        }
        if let error = error as? DemoTextResourceStoreError {
            switch error {
            case .capacityReached: return "本对话最多保留 4 份文本，其中小附件合计不超过 2 MiB。请移除未发送附件或开始新对话。"
            case .resourceTooLarge: return "粘贴文本最多 512 KiB；文件导入最多 100 MiB。"
            case .largeResourceCannotBeSaved: return "超过 512 KiB 的附件不能随会话保存。本次操作未改动存档。关闭“本机保存已完成会话”会清除旧存档；如需保留，请改用小附件。"
            case .invalidName: return "文件名无效或过长，请重命名后导入。"
            case .invalidPrivateState: return "本机文本附件记录无效，请开始新对话。"
            }
        }
        if error is DemoTextFileReadError { return "请选择 UTF-8 编码的文本文件，单份不超过 512 KiB。" }
        if error is CancellationError { return "本次操作已停止。" }
        return "操作未完成，请检查模型设置或所选附件后重试。"
    }
}
