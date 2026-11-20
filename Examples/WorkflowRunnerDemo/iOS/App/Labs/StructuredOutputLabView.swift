import SwiftUI
import BoneAgentKit

struct StructuredOutputLabView: View {
    let store: LiveChatSettingsStore
    private let onConfigureModel: () -> Void
    @State private var source = ""
    @State private var maximumCorrections = 0
    @State private var result: DemoStructuredOutputResult?
    @State private var errorMessage: String?
    @State private var requestConnection: String?
    @State private var task: Task<Void, Never>?
    @State private var cancelling = false
    @FocusState private var editing: Bool

    init(store: LiveChatSettingsStore, onConfigureModel: @escaping () -> Void = {}) {
        self.store = store
        self.onConfigureModel = onConfigureModel
    }

    var body: some View {
        Form {
            Section {
                Text("结构化专项·不使用实验室勾选的对话工具")
                    .font(.headline)
                    .accessibilityIdentifier("structuredOutputScope")
                Label(store.isUITesting ? "UI 测试替身 · 未联网" : "使用当前模型 · 点击运行后发送", systemImage: "curlybraces")
                    .font(.subheadline.weight(.medium))
                    .accessibilityIdentifier("structuredOutputMode")
                Text("下次运行：\(store.settings.modelID)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("structuredOutputModel")
                if let requestConnection {
                    LabeledContent("本次目标", value: requestConnection)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text("把原文整理为摘要和要点，并检查结果是否符合格式。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !store.hasKey && !store.isUITesting {
                    Text("请先配置模型和 API Key，再运行本专项。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("structuredConnectionStatus")
                }
                Button("配置模型", systemImage: "slider.horizontal.3") {
                    guard task == nil else { return }
                    editing = false
                    onConfigureModel()
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(task != nil)
                .accessibilityIdentifier("structuredConfigureModel")
            }
            .listRowBackground(LabStyle.surface)

            Section {
                TextField("粘贴需要整理的原文", text: $source, axis: .vertical)
                    .lineLimit(7...14)
                    .frame(minHeight: 180, alignment: .topLeading)
                    .focused($editing)
                    .accessibilityLabel("结构化输出原文")
                    .accessibilityIdentifier("structuredOutputSource")
                receiptRow("原文字节数", value: "\(source.utf8.count) / 16384", id: "structuredOutputSourceBytes")
            } header: {
                Text("原文")
            } footer: {
                Text("最多 16 KiB。运行会将原文发送给模型设置中的服务商。")
            }
            .disabled(task != nil)
            .listRowBackground(LabStyle.surface)

            Section {
                Picker("最多自动修正次数", selection: $maximumCorrections) {
                    ForEach(0...2, id: \.self) { count in Text("\(count) 次").tag(count) }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("structuredOutputCorrectionLimit")
            } header: {
                Text("有界修正")
            } footer: {
                Text("默认关闭。开启后，仅在完整结果的格式或字段校验未通过时再次请求当前模型；本次总请求最多 \(maximumCorrections + 1) 次。")
            }
            .disabled(task != nil)
            .listRowBackground(LabStyle.surface)

            if let result {
                Section("校验回执") {
                    Text(outcomeText(result.receipt.outcome))
                        .font(.headline)
                        .foregroundStyle(result.fields == nil ? Color.red : LabStyle.accent)
                        .accessibilityIdentifier("structuredOutputValidationOutcome")
                    receiptRow("实际推理次数", value: "\(result.inferenceCallCount)", id: "structuredOutputInferenceCount")
                    receiptRow("本地校验次数", value: "\(result.validationCount)", id: "structuredOutputValidationCount")
                    receiptRow("实际修正次数", value: "\(result.correctionCount)", id: "structuredOutputCorrectionCount")
                    Text("格式通过表示字段满足本地规则；请核对摘要与原文是否一致。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(LabStyle.surface)

                if let fields = result.fields {
                    Section("摘要") {
                        Text(fields.summary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("structuredOutputSummary")
                    }
                    .listRowBackground(LabStyle.surface)
                    Section("要点") {
                        if fields.keyPoints.isEmpty {
                            Text("无要点").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(fields.keyPoints.enumerated()), id: \.offset) { index, point in
                                Text("\(index + 1). \(point)")
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("structuredOutputKeyPoint\(index)")
                            }
                        }
                    }
                    .listRowBackground(LabStyle.surface)
                }
                if let prettyJSON = result.prettyJSON {
                    Section("JSON") {
                        Text(prettyJSON)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("structuredOutputJSON")
                    }
                    .listRowBackground(LabStyle.surface)
                }
            }

            if let errorMessage {
                Section("本次请求未完成") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("structuredOutputError")
                }
                .listRowBackground(LabStyle.surface)
            }
        }
        .navigationTitle("结构化输出")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editing = false }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("structuredOutputKeyboardDone")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !editing {
                HStack(spacing: LabStyle.itemSpacing) {
                    if task != nil {
                        ProgressView()
                        Text(cancelling ? "正在取消…" : "正在请求…")
                            .font(.subheadline)
                        Spacer()
                        Button("取消", role: .cancel) {
                            cancelling = true
                            task?.cancel()
                        }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                        .disabled(cancelling)
                        .accessibilityIdentifier("structuredOutputCancel")
                    } else {
                        Button(action: startRun) {
                            Label("运行", systemImage: "play.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(LabStyle.onAccent)
                        .controlSize(.large)
                        .disabled(!canRun)
                        .accessibilityIdentifier("structuredOutputRun")
                    }
                }
                .padding(.horizontal, LabStyle.pageInset)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .onChange(of: source) { _, _ in
            requestConnection = nil
            result = nil
            errorMessage = nil
        }
        .onDisappear { task?.cancel() }
    }

    private var canRun: Bool {
        (store.hasKey || store.isUITesting) &&
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        source.utf8.count <= DemoStructuredOutputService.maximumSourceBytes
    }

    private func receiptRow(_ title: String, value: String, id: String) -> some View {
        LabeledContent { Text(value).monospacedDigit().accessibilityIdentifier(id) } label: { Text(title) }
    }

    private func outcomeText(_ outcome: BoneInferenceOutputProcessingReceipt.Outcome) -> String {
        switch outcome {
        case .accepted: return "本地校验通过"
        case .rejected(.invalidFormat): return "未通过：JSON 格式不符"
        case .rejected(.contractMismatch): return "未通过：字段不符合规则"
        case .rejected: return "本地校验未通过"
        }
    }

    private func startRun() {
        guard task == nil, canRun else { return }
        editing = false
        result = nil
        errorMessage = nil
        cancelling = false
        let input = source
        let settings = store.settings
        requestConnection = "\(settings.provider.title) · \(settings.modelID)"
        let correctionLimit = maximumCorrections
        task = Task { @MainActor in
            defer {
                task = nil
                cancelling = false
            }
            do {
                try Task.checkCancellation()
                let service = DemoStructuredOutputService()
                let completed: DemoStructuredOutputResult
                if store.isUITesting {
                    completed = try await service.run(
                        source: input, settings: settings, maximumCorrections: correctionLimit,
                        engine: StructuredOutputUITestEngine()
                    )
                } else {
                    // The existing credential store is read only after this explicit Run action.
                    let key = try store.key(for: settings)
                    try Task.checkCancellation()
                    completed = try await service.run(
                        source: input, settings: settings, apiKey: key, maximumCorrections: correctionLimit
                    )
                }
                try Task.checkCancellation()
                result = completed
            } catch {
                errorMessage = safeMessage(for: error)
            }
        }
    }

    private func safeMessage(for error: Error) -> String {
        if error is CancellationError { return "请求已取消。" }
        if let configuration = error as? DemoChatConfigurationError { return configuration.message }
        if let failure = error as? DemoStructuredOutputError {
            switch failure {
            case .emptySource: return "请先输入原文。"
            case .sourceTooLarge: return "原文超过 16 KiB，请缩短后重新运行。"
            case .invalidCorrectionLimit: return "修正次数必须在 0～2 之间。"
            case .responseTooLarge: return "响应超过本次容量上限，未继续请求。"
            case .incompleteResponse: return "未收到完整结构化结果，未自动修正。"
            case .inferenceLimitReached: return "已达到本次请求次数上限。"
            }
        }
        if let failure = error as? BoneInferenceTransportError {
            switch failure {
            case .cancelled: return "请求已取消。"
            case .invalidCredential, .httpStatus(401): return "认证失败，请检查模型设置中的 API Key。"
            case .rateLimited, .httpStatus(429): return "请求过于频繁，请稍后重新运行。"
            case .quotaExceeded: return "服务商额度不足，请检查账户。"
            case .outputTruncated: return "响应被截断，未自动修正。可调整原文或回复上限后重新运行。"
            case .responseTooLarge: return "响应超过本次容量上限，未继续请求。"
            case .invalidResponse: return "服务商响应未通过 SDK 检查，未自动修正。"
            default: return "服务商请求失败，未自动重试。请检查连接和模型设置。"
            }
        }
        if let failure = error as? BoneInferenceError,
           failure == .unsupportedStructuredOutput {
            return "当前连接不支持此结构化输出方式，请选择支持的模型与服务商。"
        }
        return "请求未完成，未自动重试。请检查模型设置后重新运行。"
    }
}

/// Used only by the explicit isUITesting branch, with no key or transport access.
private struct StructuredOutputUITestEngine: BoneInferenceEngine {
    let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try Task.checkCancellation()
        let fixture = DemoStructuredSummary(summary: "UI 测试替身：示例摘要。", keyPoints: ["此结果来自注入的测试引擎，未联网。"])
        return .structured(.init(data: try JSONEncoder().encode(fixture)))
    }
}
