import SwiftUI
import BoneAgentKit

struct TextResourceLabView: View {
    private let canUseInTask: Bool
    private let onUseInTask: ((String, String) async -> Bool)?
    @State private var resourceStore = DemoTextResourceStore()
    @State private var name = "本地分页示例"
    @State private var source = Self.sample
    @State private var imported: DemoImportedTextResource?
    @State private var previewInput: ResourceInput?
    @State private var page: BoneToolTextResourcePage?
    @State private var nextOffset: Int? = 0
    @State private var pageBytes = 256
    @State private var task: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var isSharing = false
    @State private var shareErrorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case name, source }
    private enum Operation { case preview, read, clear }

    private struct ResourceInput: Equatable {
        let name: String
        let source: String
    }

    init(canUseInTask: Bool = true, onUseInTask: ((String, String) async -> Bool)? = nil) {
        self.canUseInTask = canUseInTask
        self.onUseInTask = onUseInTask
    }

    private static let sample = String(repeating:
        "文本资源留在本机；预览只是原文前缀。\nUnicode：中文、🙂、👨‍👩‍👧‍👦、e\u{301}，分页按 UTF-8 字节计。\n下一页必须使用 SDK 返回的 nextOffset。\n\n",
        count: 12)

    var body: some View {
        Form {
            Section {
                Label("本机文本 · 不发送模型请求", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.medium))
                Text("本页是本地文本专项，与对话不自动共享。粘贴或编辑文本，生成预览，再逐页回读原文。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(LabStyle.surface)

            Section {
                TextField("资源名称", text: $name)
                    .focused($focusedField, equals: .name)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("textResourceName")
                TextField("粘贴或编辑文本", text: $source, axis: .vertical)
                    .lineLimit(6...12)
                    .focused($focusedField, equals: .source)
                    .frame(minHeight: 160, alignment: .topLeading)
                    .accessibilityLabel("资源原文")
                    .accessibilityIdentifier("textResourceSource")
                countRow("原文字节数", value: "\(source.utf8.count) / 524288", id: "textResourceSourceBytes")
                Button("载入示例", systemImage: "text.badge.plus") {
                    focusedField = nil
                    name = "本地分页示例"
                    source = Self.sample
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("textResourceSample")
            } header: {
                Text("原文")
            } footer: {
                Text("每份文本最多 512 KiB。修改输入后需要重新生成预览。")
            }
            .disabled(task != nil || isSharing)
            .listRowBackground(LabStyle.surface)

            if let imported {
                Section("原文预览") {
                    Text(imported.name).font(.headline)
                    Text(imported.preview.text.isEmpty ? "（空文本）" : imported.preview.text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("textResourcePreview")
                    countRow("完整字节数", value: "\(imported.utf8ByteCount)", id: "textResourceTotalBytes")
                    countRow("预览字节数", value: "\(imported.preview.text.utf8.count)", id: "textResourcePreviewBytes")
                    countRow("预览 nextOffset", value: offsetText(imported.preview.nextOffset), id: "textResourcePreviewOffset")
                    Text(imported.preview.isTruncated ? "预览已截短；完整回读从 offset 0 开始。" : "预览已包含全文；仍可调用读取工具验证。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(LabStyle.surface)

                Section {
                    Picker("每页最多字节", selection: $pageBytes) {
                        ForEach([64, 256, 1_024, 4_096], id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("textResourcePageSize")
                    countRow("下次 offset", value: offsetText(nextOffset), id: "textResourceNextOffset")
                    if let page {
                        countRow("本页 offset", value: "\(page.offset)", id: "textResourcePageOffset")
                        countRow("本页字节数", value: "\(page.text.utf8.count)", id: "textResourcePageBytes")
                        Text(page.text.isEmpty ? "（已到末尾）" : page.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("textResourcePageText")
                    }
                    Button("从头读取", systemImage: "arrow.counterclockwise") {
                        page = nil
                        nextOffset = 0
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("textResourceRestart")
                    Button("移除本页资源", systemImage: "trash", role: .destructive) { perform(.clear) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("textResourceClear")
                } header: {
                    Text("SDK 分页读取")
                } footer: {
                    Text("实际调用 resource.readText；字节页边界由 SDK 处理，组合字符可能跨页。null 表示结束。")
                }
                .disabled(task != nil || isSharing)
                .listRowBackground(LabStyle.surface)
            }

            if onUseInTask != nil {
                Section {
                    Button(action: useResourceInTask) {
                        HStack(spacing: 8) {
                            if isSharing { ProgressView() }
                            Label("加入工具任务", systemImage: "text.badge.plus")
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(!canShare)
                    .accessibilityIdentifier("useResourceInTask")
                    if !canUseInTask {
                        Text("当前工具任务暂不能接收材料，请稍后重试。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("textResourceTaskUnavailable")
                    }
                    if let shareErrorMessage {
                        Text(shareErrorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("textResourceShareError")
                    }
                } header: {
                    Text("加入当前工具任务")
                } footer: {
                    Text("先生成本地预览，再加入对应的名称和完整原文。成功后返回实验室，保留任务输入并添加待发送材料；点击任务运行后才发送给模型。")
                }
                .listRowBackground(LabStyle.surface)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("textResourceError")
                }
                .listRowBackground(LabStyle.surface)
            }
        }
        .navigationTitle("文本资源")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("textResourceKeyboardDone")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if focusedField == nil {
                Button {
                    perform(imported == nil ? .preview : .read)
                } label: {
                    HStack(spacing: 8) {
                        if task != nil { ProgressView().tint(LabStyle.onAccent) }
                        Text(imported == nil ? "生成本地预览" : (nextOffset == nil ? "已读到末尾" : "读取下一页"))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .foregroundStyle(LabStyle.onAccent)
                .controlSize(.large)
                .disabled(task != nil || isSharing || (imported == nil && !canPreview) || (imported != nil && nextOffset == nil))
                .accessibilityIdentifier(imported == nil ? "textResourceMakePreview" : "textResourceReadNext")
                .padding(.horizontal, LabStyle.pageInset)
                .padding(.vertical, 12)
                .background(.bar)
            }
        }
        .onChange(of: source) { _, _ in invalidatePreview() }
        .onChange(of: name) { _, _ in invalidatePreview() }
        .onDisappear { task?.cancel() }
    }

    private var canPreview: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        name.utf8.count <= DemoTextResourceStore.maximumNameBytes &&
        source.utf8.count <= DemoTextResourceStore.maximumResourceBytes
    }

    private var currentInput: ResourceInput { .init(name: name, source: source) }

    private var canShare: Bool {
        canUseInTask && !isSharing && task == nil && imported != nil && previewInput == currentInput
    }

    private func countRow(_ title: String, value: String, id: String) -> some View {
        LabeledContent { Text(value).monospacedDigit().accessibilityIdentifier(id) } label: { Text(title) }
    }

    private func offsetText(_ value: Int?) -> String { value.map(String.init) ?? "null · 结束" }

    private func invalidatePreview() {
        imported = nil
        previewInput = nil
        page = nil
        nextOffset = 0
        errorMessage = nil
        shareErrorMessage = nil
    }

    private func useResourceInTask() {
        guard canShare, let input = previewInput, let onUseInTask else { return }
        focusedField = nil
        shareErrorMessage = nil
        isSharing = true
        // Parent owns the import lifetime. Leaving this page must not cancel it.
        Task { @MainActor in
            defer { isSharing = false }
            if !(await onUseInTask(input.name, input.source)) {
                shareErrorMessage = "未能加入工具任务，请稍后重试或返回实验室检查任务状态。"
            }
        }
    }

    private func perform(_ operation: Operation) {
        guard task == nil, !isSharing else { return }
        focusedField = nil
        errorMessage = nil
        shareErrorMessage = nil
        let input = currentInput
        task = Task { @MainActor in
            defer { task = nil }
            do {
                try Task.checkCancellation()
                switch operation {
                case .preview:
                    await resourceStore.clear()
                    let resource = try await resourceStore.add(name: input.name, text: input.source)
                    try Task.checkCancellation()
                    guard input == currentInput else { return }
                    imported = resource
                    previewInput = input
                    page = nil
                    nextOffset = 0
                case .read:
                    guard let imported, let nextOffset else { return }
                    let request = try BoneToolTextResourceReadRequest(
                        reference: imported.preview.reference, offset: nextOffset, maximumBytes: pageBytes
                    )
                    let data = try await resourceStore.makeReadTool().execute(
                        input: JSONEncoder().encode(request), context: BoneAgentEmptyContext()
                    )
                    try Task.checkCancellation()
                    let received = try JSONDecoder().decode(BoneToolTextResourcePage.self, from: data)
                    page = received
                    self.nextOffset = received.nextOffset
                case .clear:
                    await resourceStore.clear()
                    invalidatePreview()
                }
            } catch is CancellationError {
                errorMessage = "本地读取已取消。"
            } catch {
                errorMessage = "本地文本未通过校验，请检查名称和容量后重新生成预览。"
            }
        }
    }
}
