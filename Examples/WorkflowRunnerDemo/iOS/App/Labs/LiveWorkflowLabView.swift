import SwiftUI
import Observation
import BoneAgentKit
import BoneAgentTesting

struct LiveWorkflowLabView: View {
    let store: LiveChatSettingsStore
    private let calculatorEnabled: Bool?
    private let onConfigureModel: () -> Void
    private let onConfigureTools: () -> Void
    @State private var model = LiveWorkflowLabModel()
    @State private var prompt = "请计算 17 × 23，并简要解释结果。若有计算器工具，请使用它。"
    @State private var mode: DemoRunMode = .planning
    @State private var recoverableSessionInput = "继续执行"

    init(store: LiveChatSettingsStore, calculatorEnabled: Bool? = nil,
         onConfigureModel: @escaping () -> Void = {}, onConfigureTools: @escaping () -> Void = {}) {
        self.store = store
        self.calculatorEnabled = calculatorEnabled
        self.onConfigureModel = onConfigureModel
        self.onConfigureTools = onConfigureTools
    }

    private var selectedCalculator: Bool { calculatorEnabled ?? store.settings.enablesCalculator }

    private var settings: DemoLiveChatSettings {
        if let frozen = model.frozenSettings { return frozen }
        var proposed = store.settings
        proposed.enablesCalculator = selectedCalculator
        return proposed
    }

    var body: some View {
        Form {
            Section {
                Label("模型驱动的单步 Workflow", systemImage: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(LabStyle.accent)
                    .font(.headline)
                Text("一个冻结的 Plan、一个 Agent Step。模型可在步骤内多轮调用本专项的只读计算器；Run 与 Step 均由 SDK 控制器推进。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("Workflow专项仅使用计算器，其他勾选工具请在工具任务运行。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workflowToolScope")
                if store.isUITesting {
                    Label("脚本模型 · 不联网", systemImage: "network.slash")
                        .accessibilityIdentifier("workflowOfflineMode")
                }
            }
            .listRowBackground(LabStyle.surface)

            Section {
                LabeledContent("服务商", value: settings.provider.title)
                LabeledContent("模型", value: settings.modelID)
                    .textSelection(.enabled)
                LabeledContent("工具范围", value: settings.enablesCalculator ? "本地只读计算器" : "无工具")
                    .accessibilityIdentifier("workflowCalculatorScope")
                LabeledContent("单次回复上限", value: "\(settings.maximumOutputTokens) tokens")
                if !store.hasKey && !store.isUITesting {
                    Text("缺少 API Key，请先配置模型。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("workflowConnectionStatus")
                }
                Button("配置模型", systemImage: "slider.horizontal.3") {
                    guard !model.isWorking else { return }
                    onConfigureModel()
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(model.isWorking)
                .accessibilityIdentifier("workflowConfigureModel")
                Button("调整工具选择", systemImage: "checklist") {
                    guard !model.isWorking else { return }
                    onConfigureTools()
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(model.isWorking)
                .accessibilityIdentifier("workflowConfigureTools")
            } header: { Text(model.hasStartedExperiment ? "本次已冻结的设置" : "本次待冻结的设置") }
              footer: {
                  Text(model.hasStartedExperiment
                       ? "本次继续使用上方快照。后续模型与工具选择需在“新建实验”后再次启动才生效。"
                       : "启动传统 Workflow 或创建可恢复 Session 时冻结当前模型设置与计算器选择。只有实际执行模型轮次时才发送请求。")
              }
            .listRowBackground(LabStyle.surface)

            Section {
                Picker("运行模式", selection: $mode) {
                    Text("规划 Planning").tag(DemoRunMode.planning)
                    Text("执行 Executing").tag(DemoRunMode.executing)
                }
                .frame(minHeight: 44)
                .disabled(model.hasStartedExperiment)
                .accessibilityIdentifier("workflowMode")
                TextField("输入交给模型的问题", text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .frame(minHeight: 100, alignment: .topLeading)
                    .disabled(model.hasStartedExperiment)
                    .accessibilityIdentifier("workflowPrompt")
                LabeledContent("输入大小", value: "\(prompt.utf8.count) / 16384 bytes")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("输入与模式") }
              footer: {
                  Text("Planning 只允许普通只读工具。本实验仅注册只读计算器，Executing 也不获得写入能力；Prompt 文字不会授予工具权限。")
              }

            Section {
                Button {
                    model.run(prompt: prompt, mode: mode, store: store, calculatorEnabled: selectedCalculator)
                } label: {
                    Label(store.isUITesting ? "Run · 不联网" : "Run · 开始实验", systemImage: "play.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(LabStyle.accent)
                .foregroundStyle(LabStyle.onAccent)
                .disabled(model.hasStartedExperiment || model.isWorking || !validPrompt || (!store.hasKey && !store.isUITesting))
                .accessibilityIdentifier("workflowRun")

                Button(role: .destructive) { model.stop() } label: {
                    Label(model.stopRequested ? "正在等待停止确认…" : "Stop · 停止", systemImage: "stop.fill")
                        .frame(minHeight: 44)
                }
                .disabled(!model.canStopLegacy || model.stopRequested)
                .accessibilityIdentifier("workflowStop")
                if model.legacyIsWorking {
                    ProgressView(model.stopRequested ? "等待实际终态或恢复状态" : "正在推进 Run / Step…")
                }
                if let message = model.message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } footer: {
                Text("最多 6 次模型调用、8 次工具调用；累计输入 512 KiB、输出 256 KiB。120 秒为 SDK 操作边界截止；网络请求设置超时和响应大小上限。失败与取消均不自动重试。")
            }

            if let inspection = model.inspection {
                stateSection(inspection)
                Section {
                    Text(inspection.recovery.message)
                        .font(.subheadline).foregroundStyle(.secondary)
                    Button("Inspect · 重读检查点") { model.inspectNow() }
                        .frame(minHeight: 44)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("workflowInspect")
                    if inspection.recovery == .closeConfirmedStep {
                        Button("安全恢复 · 仅收口已确认 Step") { model.closeConfirmedStep() }
                            .frame(minHeight: 44)
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("workflowSafeRecovery")
                    }
                    DisclosureGroup("检查点元数据") {
                        Text(String(decoding: inspection.snapshot.checkpoint.payload, as: UTF8.self))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    DisclosureGroup("提交与读取证据 · \(inspection.evidence.count) 项") {
                        ForEach(inspection.evidence) { evidence in
                            Text(evidence.text)
                                .font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("workflowEvidence")
                } header: { Text("检查与安全收口") }
                  footer: { Text("不会在启动或返回页面时恢复。未知派发仅供检查；安全收口会重验 revision 和 SDK 检查点兼容性，不重新调用模型或工具。") }
            }

            if let response = model.finalResponse {
                Section("最终响应") {
                    Text(response)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("workflowFinalResponse")
                }
            } else if model.inspection?.snapshot.run.state == .completed {
                Section("最终响应") {
                    Text("本次进程内没有保留可展示的最终文本。检查点只记录元数据，无法重建缺失的输出。")
                        .foregroundStyle(.secondary)
                }
            }

            recoverableSessionSection

            Section {
                Button("新建实验") { model.reset() }
                    .frame(minHeight: 44)
                    .disabled(model.isWorking || !model.hasStartedExperiment)
                    .accessibilityIdentifier("workflowNewExperiment")
                Text("持久化范围：本次进程内。原始输入和最终响应只驻留私有内存；新建实验会释放当前 Host。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("本实验演示固定单步流程与 CAS 检查点；不提供跨进程崩溃恢复、生产授权界面、动态 DAG 或恰好一次的外部副作用保证。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .tint(LabStyle.accent)
        .navigationTitle("真实模型 Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { model.stop() }
    }

    private var validPrompt: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prompt.utf8.count <= DemoLiveWorkflow.maximumPromptBytes
    }

    /// 展示可恢复 Agent Session 的创建、等待、恢复和控制面检查入口。
    /// - Returns: 与旧 Workflow Runner 并列的 Session 实验区。
    @ViewBuilder
    private var recoverableSessionSection: some View {
        Section {
            Text("此入口演示 BoneAgentExecutionSessionCoordinator 的控制面。创建 Session 不会请求模型，等待用户后才由 Host 显式恢复并发送下一轮输入。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if store.isUITesting {
                Label("脚本模型 · 不联网", systemImage: "network.slash")
                    .accessibilityIdentifier("recoverableSessionOfflineMode")
            }

            TextField("发送给可恢复 Session 的输入", text: $recoverableSessionInput, axis: .vertical)
                .lineLimit(3...6)
                .frame(minHeight: 76, alignment: .topLeading)
                .disabled(model.isWorking || !model.recoverableSessionStarted)
                .accessibilityIdentifier("recoverableSessionInput")

            Button("创建可恢复 Session", systemImage: "externaldrive.badge.timemachine") {
                model.createRecoverableSession(store: store, calculatorEnabled: selectedCalculator)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .buttonStyle(.borderedProminent)
            .tint(LabStyle.accent)
            .foregroundStyle(LabStyle.onAccent)
            .disabled(model.hasStartedExperiment || model.isWorking || (!store.hasKey && !store.isUITesting))
            .accessibilityIdentifier("recoverableSessionCreate")

            Button("等待用户输入", systemImage: "pause.circle") {
                model.waitForRecoverableSessionUser()
            }
            .frame(minHeight: 44)
            .disabled(model.isWorking || !model.canWaitForRecoverableUser)
            .accessibilityIdentifier("recoverableSessionWaitForUser")

            Button(model.canResumeRecoverableSession ? "恢复并发送下一轮" : "发送一轮输入", systemImage: "arrow.continue") {
                model.sendRecoverableSessionInput(userMessage: recoverableSessionInput)
            }
            .frame(minHeight: 44)
            .disabled(model.isWorking || !model.canSendRecoverableInput || recoverableSessionInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("recoverableSessionSend")

            Button("Inspect · 读取 Session 状态", systemImage: "info.circle") {
                model.inspectRecoverableSession()
            }
            .frame(minHeight: 44)
            .disabled(model.isWorking || !model.recoverableSessionStarted)
            .accessibilityIdentifier("recoverableSessionInspect")

            if model.isWorking {
                ProgressView("正在处理可恢复 Session…")
            }
            if let message = model.recoverableSessionMessage {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("recoverableSessionMessage")
            }
            if let inspection = model.recoverableSessionInspection {
                recoverableSessionStateSection(inspection)
            }
        } header: {
            Text("可恢复 Agent Session")
        } footer: {
            Text("Demo 使用进程内联合内存 Store，仅用于展示 Session、快照引用、revision 和 lease generation 的调用顺序。生产 Host 仍需提供加密数据库、跨进程 CAS、崩溃恢复和未知副作用对账。")
        }
        .listRowBackground(LabStyle.surface)
    }

    /// 展示可恢复 Session 的控制面状态和本轮模型输出。
    /// - Parameter value: Host 返回的 Session 检查结果。
    /// - Returns: 可读的 Session 状态区。
    @ViewBuilder
    private func recoverableSessionStateSection(_ value: DemoRecoverableAgentSessionInspection) -> some View {
        LabeledContent("Session 状态", value: value.session.state.rawValue)
            .accessibilityIdentifier("recoverableSessionState")
        LabeledContent("Session revision", value: "\(value.session.revision)")
            .accessibilityIdentifier("recoverableSessionRevision")
        LabeledContent("Conversation revision", value: "\(value.session.snapshotReference?.conversationRevision ?? 0)")
            .accessibilityIdentifier("recoverableSessionConversationRevision")
        LabeledContent("Lease generation", value: "\(value.session.leaseGeneration)")
            .accessibilityIdentifier("recoverableSessionLeaseGeneration")
        LabeledContent("Snapshot reference", value: value.session.snapshotReference?.referenceID ?? "未创建")
            .font(.caption)
            .textSelection(.enabled)
            .accessibilityIdentifier("recoverableSessionSnapshotReference")
        if let attention = value.session.attention {
            LabeledContent("Attention", value: attentionDescription(attention))
                .accessibilityIdentifier("recoverableSessionAttention")
        }
        if let output = value.output {
            Text("Session 本轮输出")
                .font(.headline)
            Text(outputDescription(output))
                .textSelection(.enabled)
                .accessibilityIdentifier("recoverableSessionOutput")
        }
    }

    /// 将 Session 的 Attention 转换为 UI 可读文本。
    /// - Parameter attention: SDK 返回的等待或恢复关注事项。
    /// - Returns: 不包含敏感正文的状态描述。
    private func attentionDescription(_ attention: BoneAgentExecutionAttention) -> String {
        switch attention {
        case .userInput(let requestID): return "等待用户输入（\(requestID)）"
        case .authorization(let ticketID): return "等待授权（\(ticketID.rawValue)）"
        case .review(let reviewID): return "等待审核（\(reviewID)）"
        case .externalEvent(let eventID): return "等待外部事件（\(eventID)）"
        case .recovery(let reason): return "需要恢复处理（\(reason.rawValue)）"
        }
    }

    /// 将 Agent 输出转换为可展示文本，避免 UI 依赖私有 Conversation 快照。
    /// - Parameter output: SDK 返回的文本或结构化结果。
    /// - Returns: 适合展示和复制的输出文本。
    private func outputDescription(_ output: BoneAgentRunOutput) -> String {
        switch output {
        case .text(let text): return text
        case .structured(let data): return String(decoding: data, as: UTF8.self)
        }
    }

    private func stateSection(_ value: DemoLiveWorkflowInspection) -> some View {
        Section("实际 Run / Step 状态") {
            LabeledContent("Run", value: value.snapshot.run.state.rawValue)
                .accessibilityIdentifier("workflowRunState")
            LabeledContent("Step", value: value.checkpoint.step.state.rawValue)
                .accessibilityIdentifier("workflowStepState")
            LabeledContent("Run ID", value: value.snapshot.run.id.rawValue)
                .font(.caption).textSelection(.enabled)
            LabeledContent("Run / Checkpoint revision", value: "\(value.snapshot.run.revision) / \(value.snapshot.checkpoint.revision)")
            LabeledContent("Step revision", value: "\(value.checkpoint.step.persistenceRevision)")
            LabeledContent("Lease generation", value: "\(value.snapshot.run.leaseGeneration)")
            LabeledContent("派发阶段", value: value.checkpoint.phase.rawValue)
            LabeledContent("已确认模型响应", value: "\(value.checkpoint.step.inferenceResponseCount)")
            LabeledContent("已确认工具结果", value: "\(value.checkpoint.step.toolResultCount)")
            LabeledContent("取消已确认", value: value.checkpoint.step.cancellationPersisted ? "是" : "否")
            LabeledContent("检查点兼容性", value: value.compatibility == .resumeCompatible ? "SDK resumeCompatible" : "禁止恢复")
        }
    }
}

@Observable
@MainActor
private final class LiveWorkflowLabModel {
    private(set) var isWorking = false
    private(set) var stopRequested = false
    private(set) var didStart = false
    /// 可恢复 Session 是否已创建并冻结本次 Demo 配置。
    private(set) var recoverableSessionStarted = false
    private(set) var frozenSettings: DemoLiveChatSettings?
    private(set) var inspection: DemoLiveWorkflowInspection?
    private(set) var finalResponse: String?
    private(set) var message: String?
    /// 当前可恢复 Session 的状态和本轮输出。
    private(set) var recoverableSessionInspection: DemoRecoverableAgentSessionInspection?
    /// 当前可恢复 Session 操作的用户可读错误或提示。
    private(set) var recoverableSessionMessage: String?
    @ObservationIgnored private var host: DemoLiveWorkflow?
    @ObservationIgnored private var recoverableHost: DemoLiveWorkflow?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var observer: Task<Void, Never>?

    /// 当前实验是否已经冻结了模型和工具配置。
    /// - Returns: 传统 Workflow 或可恢复 Session 任一已启动时返回 true。
    var hasStartedExperiment: Bool { didStart || recoverableSessionStarted }

    /// 传统 Workflow 是否正在占用本地工作任务。
    /// - Returns: 只有传统 Workflow 启动后且当前任务未结束时返回 true。
    var legacyIsWorking: Bool { didStart && isWorking }

    /// 传统 Workflow 是否允许由 Stop 按钮取消本地任务。
    /// - Returns: 传统 Workflow 正在执行且尚未请求停止时返回 true。
    var canStopLegacy: Bool { legacyIsWorking && !stopRequested }

    /// 当前 Session 是否处于可以等待用户输入的运行态。
    /// - Returns: Session 已创建且状态允许写入 waitingForUser 时返回 true。
    var canWaitForRecoverableUser: Bool {
        guard let state = recoverableSessionInspection?.session.state else { return false }
        return state == .active || state == .paused
    }

    /// 当前 Session 是否处于等待用户后可以恢复的状态。
    /// - Returns: Session 状态为 waitingForUser 时返回 true。
    var canResumeRecoverableSession: Bool {
        recoverableSessionInspection?.session.state == .waitingForUser
    }

    /// 当前 Session 是否允许发送一轮用户输入。
    /// - Returns: Session 处于 active、paused 或 waitingForUser 时返回 true。
    var canSendRecoverableInput: Bool {
        guard let state = recoverableSessionInspection?.session.state else { return false }
        return state == .active || state == .paused || state == .waitingForUser
    }

    func run(prompt: String, mode: DemoRunMode, store: LiveChatSettingsStore, calculatorEnabled: Bool) {
        guard !isWorking, !hasStartedExperiment, store.hasKey || store.isUITesting else { return }
        var proposed = store.settings
        proposed.enablesCalculator = calculatorEnabled
        let settings = proposed
        frozenSettings = settings
        didStart = true
        isWorking = true
        message = nil
        worker = Task {
            do {
                try Task.checkCancellation()
                let host = try makeHost(settings: settings, store: store, recoverable: false)
                self.host = host
                observe(host)
                inspection = try await host.start(prompt: prompt, mode: mode)
                finalResponse = await host.finalResponse()
                message = inspection?.failure?.message
            } catch {
                message = safeMessage(error)
            }
            observer?.cancel()
            observer = nil
            isWorking = false
            stopRequested = false
            worker = nil
        }
    }

    func stop() {
        guard canStopLegacy else { return }
        stopRequested = true
        worker?.cancel()
    }

    /// 创建可恢复 Session，并只保存初始控制面和空 Conversation 快照。
    /// - Parameters:
    ///   - store: 提供模型设置和 UI 测试模式信息的 Host Store。
    ///   - calculatorEnabled: 本次冻结的只读计算器开关。
    /// - Returns: 无返回值，结果通过可观察状态发布。
    func createRecoverableSession(store: LiveChatSettingsStore, calculatorEnabled: Bool) {
        guard !isWorking, !hasStartedExperiment, store.hasKey || store.isUITesting else { return }
        var proposed = store.settings
        proposed.enablesCalculator = calculatorEnabled
        let settings = proposed
        frozenSettings = settings
        recoverableSessionStarted = true
        recoverableSessionMessage = nil
        isWorking = true
        worker = Task {
            do {
                let host = try makeHost(settings: settings, store: store, recoverable: true)
                recoverableHost = host
                recoverableSessionInspection = try await host.createRecoverableSession()
            } catch {
                recoverableSessionMessage = safeMessage(error)
                recoverableSessionStarted = false
                frozenSettings = nil
            }
            finishAction()
        }
    }

    /// 将可恢复 Session 置为等待用户状态，不发起模型请求。
    /// - Returns: 无返回值，结果通过可观察状态发布。
    func waitForRecoverableSessionUser() {
        guard !isWorking, let host = recoverableHost, canWaitForRecoverableUser else { return }
        recoverableSessionMessage = nil
        isWorking = true
        worker = Task {
            do {
                recoverableSessionInspection = try await host.waitForRecoverableSessionUser(requestID: "ios-user-input")
            } catch {
                recoverableSessionMessage = safeMessage(error)
            }
            finishAction()
        }
    }

    /// 根据当前 Session 状态发送输入或恢复等待用户的 Session。
    /// - Parameter userMessage: 当前输入框中的用户消息。
    /// - Returns: 无返回值，结果通过可观察状态发布。
    func sendRecoverableSessionInput(userMessage: String) {
        guard !isWorking, let host = recoverableHost, canSendRecoverableInput,
              !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        recoverableSessionMessage = nil
        isWorking = true
        worker = Task {
            do {
                if canResumeRecoverableSession {
                    recoverableSessionInspection = try await host.resumeRecoverableSession(userMessage: userMessage)
                } else {
                    recoverableSessionInspection = try await host.runRecoverableSession(userMessage: userMessage)
                }
            } catch {
                recoverableSessionMessage = safeMessage(error)
            }
            finishAction()
        }
    }

    /// 重新读取可恢复 Session 控制面，不触发模型调用。
    /// - Returns: 无返回值，结果通过可观察状态发布。
    func inspectRecoverableSession() {
        guard !isWorking, let host = recoverableHost else { return }
        recoverableSessionMessage = nil
        isWorking = true
        worker = Task {
            do {
                recoverableSessionInspection = try await host.inspectRecoverableSession()
            } catch {
                recoverableSessionMessage = safeMessage(error)
            }
            finishAction()
        }
    }

    func inspectNow() {
        guard !isWorking, let host else { return }
        isWorking = true
        worker = Task {
            do {
                inspection = try await host.inspect()
                finalResponse = await host.finalResponse()
                message = inspection?.failure?.message
            } catch { message = safeMessage(error) }
            finishAction()
        }
    }

    func closeConfirmedStep() {
        guard !isWorking, let host, let inspection,
              inspection.recovery == .closeConfirmedStep else { return }
        isWorking = true
        worker = Task {
            do {
                self.inspection = try await host.closeConfirmedStep(expectedRevision: inspection.snapshot.run.revision)
                finalResponse = await host.finalResponse()
                message = self.inspection?.failure?.message
            } catch { message = safeMessage(error) }
            finishAction()
        }
    }

    func reset() {
        guard !isWorking else { return }
        observer?.cancel()
        observer = nil
        host = nil
        recoverableHost = nil
        inspection = nil
        recoverableSessionInspection = nil
        finalResponse = nil
        frozenSettings = nil
        message = nil
        recoverableSessionMessage = nil
        recoverableSessionStarted = false
        didStart = false
    }

    /// 根据当前 Demo 配置构造传统或可恢复流程使用的 Host。
    /// - Parameters:
    ///   - settings: 已冻结并待验证的聊天设置。
    ///   - store: 提供 UI 测试标记和凭据读取的 Host Store。
    ///   - recoverable: 是否注入两轮脚本响应以覆盖 Session 恢复路径。
    /// - Returns: 已注入模型或已绑定凭据的 Demo Host。
    /// - Throws: 配置校验或凭据读取失败时抛出错误。
    private func makeHost(settings: DemoLiveChatSettings, store: LiveChatSettingsStore,
                          recoverable: Bool) throws -> DemoLiveWorkflow {
        if store.isUITesting {
            let script: [BoneInferenceResponse] = recoverable
                ? [
                    .finish(.init(text: "脚本验证完成：可恢复 Session 第一轮。")),
                    .finish(.init(text: "脚本验证完成：可恢复 Session 第二轮。"))
                ]
                : [.finish(.init(text: "脚本验证完成：此 Workflow 使用注入模型，不联网。"))]
            return try DemoLiveWorkflow.make(settings: settings, engine: BoneScriptedInferenceEngine(script: script))
        }
        let key = try store.key(for: settings)
        return try DemoLiveWorkflow.make(settings: settings, apiKey: key)
    }

    private func observe(_ host: DemoLiveWorkflow) {
        observer = Task { [weak self] in
            while !Task.isCancelled {
                if let value = try? await host.inspect(), !Task.isCancelled { self?.inspection = value }
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
    }

    private func finishAction() {
        isWorking = false
        stopRequested = false
        worker = nil
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? DemoChatConfigurationError { return error.message }
        if let error = error as? DemoLiveWorkflowFailure { return error.message }
        if let error = error as? BoneAgentExecutionSessionCoordinatorError {
            switch error {
            case .missingSnapshot, .snapshotBindingMismatch, .configurationDrift,
                 .providerContinuationInvalid, .recoveryRequired:
                return "可恢复 Session 需要 Host 调和后重新创建协调器，未自动重发模型请求。"
            case .persistenceOutcomeUnknown:
                return "Session 提交结果未知，请先重读持久化事实，未自动重试。"
            default:
                return "可恢复 Session 未完成，请检查 Host 持久化和恢复状态。"
            }
        }
        if error is CancellationError { return DemoLiveWorkflowFailure.cancelled.message }
        return DemoLiveWorkflowFailure.executionFailed.message
    }
}
