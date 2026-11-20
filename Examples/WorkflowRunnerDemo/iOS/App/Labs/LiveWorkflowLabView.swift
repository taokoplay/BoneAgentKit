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
            } header: { Text(model.didStart ? "本次已冻结的设置" : "本次待冻结的设置") }
              footer: {
                  Text(model.didStart
                       ? "本次继续使用上方快照。后续模型与工具选择需在“新建实验”后再次启动才生效。"
                       : "启动时冻结当前模型设置与计算器选择。只有点击 Run 才读取 Key 并请求模型。")
              }
            .listRowBackground(LabStyle.surface)

            Section {
                Picker("运行模式", selection: $mode) {
                    Text("规划 Planning").tag(DemoRunMode.planning)
                    Text("执行 Executing").tag(DemoRunMode.executing)
                }
                .frame(minHeight: 44)
                .disabled(model.didStart)
                .accessibilityIdentifier("workflowMode")
                TextField("输入交给模型的问题", text: $prompt, axis: .vertical)
                    .lineLimit(4...8)
                    .frame(minHeight: 100, alignment: .topLeading)
                    .disabled(model.didStart)
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
                .disabled(model.didStart || model.isWorking || !validPrompt || (!store.hasKey && !store.isUITesting))
                .accessibilityIdentifier("workflowRun")

                Button(role: .destructive) { model.stop() } label: {
                    Label(model.stopRequested ? "正在等待停止确认…" : "Stop · 停止", systemImage: "stop.fill")
                        .frame(minHeight: 44)
                }
                .disabled(!model.isWorking || model.stopRequested)
                .accessibilityIdentifier("workflowStop")
                if model.isWorking {
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

            Section {
                Button("新建实验") { model.reset() }
                    .frame(minHeight: 44)
                    .disabled(model.isWorking || !model.didStart)
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
    private(set) var frozenSettings: DemoLiveChatSettings?
    private(set) var inspection: DemoLiveWorkflowInspection?
    private(set) var finalResponse: String?
    private(set) var message: String?
    @ObservationIgnored private var host: DemoLiveWorkflow?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var observer: Task<Void, Never>?

    func run(prompt: String, mode: DemoRunMode, store: LiveChatSettingsStore, calculatorEnabled: Bool) {
        guard !isWorking, !didStart, store.hasKey || store.isUITesting else { return }
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
                let host: DemoLiveWorkflow
                if store.isUITesting {
                    // Explicit injection, no key lookup and no network fallback.
                    let engine = BoneScriptedInferenceEngine(script: [
                        .finish(.init(text: "脚本验证完成：此 Workflow 使用注入模型，不联网。"))
                    ])
                    host = try DemoLiveWorkflow.make(settings: settings, engine: engine)
                } else {
                    let key = try store.key(for: settings)
                    host = try DemoLiveWorkflow.make(settings: settings, apiKey: key)
                }
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
        guard isWorking, !stopRequested else { return }
        stopRequested = true
        worker?.cancel()
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
        inspection = nil
        finalResponse = nil
        frozenSettings = nil
        message = nil
        didStart = false
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
        if error is CancellationError { return DemoLiveWorkflowFailure.cancelled.message }
        return DemoLiveWorkflowFailure.executionFailed.message
    }
}
