import SwiftUI

struct LiveModelBudgetFields: View {
    @Binding var draft: DemoLiveChatSettings
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case output, context, summary }

    var body: some View {
        Group {
            modelFacts
            recommendation
            outputBudget
            Toggle("流式回复", isOn: $draft.usesStreaming)
                .frame(minHeight: 44)
                .accessibilityIdentifier("streamingToggle")
            Toggle("自动上下文压缩", isOn: $draft.managesContext)
                .frame(minHeight: 44)
                .accessibilityIdentifier("contextManagementToggle")
            if draft.managesContext {
                contextBudget
                Toggle("使用模型摘要", isOn: summaryEnabled)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("summaryToggle")
                Text("上下文用量达到 85% 时自动整理，目标为 65%；默认裁剪旧的完整轮次。使用模型摘要时，每次摘要会额外发起一次模型请求，并计入服务商计费与用量。")
                    .font(.footnote).foregroundStyle(.secondary)
                if draft.summarizesContext {
                    summaryBudget
                    Toggle("压缩当前任务的旧工具记录", isOn: toolHistoryCompaction)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("toolHistoryCompactionToggle")
                    Text("这是有损压缩：保留当前用户问题和最近两组完整交换。模型摘要失败时可回退到裁剪，不保证保真。仅在自动上下文压缩、模型摘要和此开关均开启时生效；关闭摘要后不激活。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("模型摘要已关闭，当前任务的旧工具记录压缩不激活。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Text("输入上下文压缩不会提高输出上限，也不会续写已截断的回复。本机窗口不能扩大模型真实容量。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var modelFacts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模型容量（资料声明）").font(.subheadline.bold())
            Text("模型上下文：\(tokenDescription(draft.modelCapacity.contextWindowTokens))")
            Text("模型最大输出：\(tokenDescription(draft.modelCapacity.maximumOutputTokens))")
            Text("来源：\(draft.modelCapacity.sourceTitle.isEmpty ? "未知" : draft.modelCapacity.sourceTitle)")
            if let sourceURL = draft.modelCapacity.sourceURL {
                Link("查看容量来源", destination: sourceURL)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("modelCapacitySourceLink")
            }
            if let verifiedAt = draft.modelCapacity.verifiedAt {
                Text("资料日期：\(verifiedAt)")
            }
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var recommendation: some View {
        if let output = draft.modelCapacity.recommendedOutputTokens,
           let window = draft.modelCapacity.contextWindowTokens {
            VStack(alignment: .leading, spacing: 8) {
                Button("填入模型建议") {
                    draft.useRecommendedModelCapacity()
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("useRecommendedModelCapacity")
                Text("输出预算：\(draft.maximumOutputTokens.formatted()) → \(output.formatted()) tokens；本机窗口：\(draft.contextWindowTokens.formatted()) → \(window.formatted()) tokens。保存后用于下次请求，不会自动发送请求。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var outputBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            numberField("当前请求输出预算（tokens）", value: $draft.maximumOutputTokens,
                        field: .output, identifier: "maximumOutputTokensField")
            Menu {
                ForEach(draft.replyLimitChoices, id: \.self) { value in
                    Button("\(value.formatted()) tokens") { draft.maximumOutputTokens = value }
                }
            } label: {
                Label("选择常用输出预算", systemImage: "chevron.up.chevron.down")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("replyLimitPicker")
            Text("可填写 128–\(draft.modelCapacity.selectableOutputMaximum.formatted()) tokens；此数值是单次请求的输出预算。")
                .font(.footnote).foregroundStyle(.secondary)
            Text("当前有效窗口：\(draft.effectiveContextWindowTokens.formatted()) tokens")
                .font(.subheadline.monospacedDigit())
            if !draft.managesContext {
                Text("自动上下文压缩已关闭；开启后才按此窗口自动整理历史。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if draft.modelCapacity.outputIncludesThinking {
                Text("MiniMax 的思考和正文共用输出预算；1,024 tokens 可能在生成正文前耗尽。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var contextBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("本机窗口上限", selection: $draft.contextWindowTokens) {
                ForEach(draft.contextWindowChoices, id: \.self) { value in
                    Text("\(value.formatted()) tokens").tag(value)
                }
                if !draft.contextWindowChoices.contains(draft.contextWindowTokens) {
                    Text("自定义：\(draft.contextWindowTokens.formatted()) tokens").tag(draft.contextWindowTokens)
                }
            }
            .pickerStyle(.menu)
            .frame(minHeight: 44)
            .accessibilityIdentifier("contextWindowPicker")
            numberField("自定义本机窗口（tokens）", value: $draft.contextWindowTokens,
                        field: .context, identifier: "contextWindowTokensField")
            if let available = draft.availableInputTokens {
                Text("预留输出预算后，可用输入：\(available.formatted()) tokens")
                    .font(.subheadline.monospacedDigit())
            } else {
                Text("当前窗口无法提供有效的输入预算，请减小输出预算或调整本机窗口。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var summaryBudget: some View {
        VStack(alignment: .leading, spacing: 8) {
            numberField("摘要输出预算（tokens）", value: summaryOutputBudget,
                        field: .summary, identifier: "summaryOutputTokensField")
            Menu {
                ForEach(summaryChoices, id: \.self) { value in
                    Button("\(value.formatted()) tokens") { draft.contextSummaryOutputTokens = value }
                }
            } label: {
                Label("选择摘要输出预算", systemImage: "chevron.up.chevron.down")
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("summaryOutputTokensPicker")
            Text("这是额外摘要请求的输出预算，可填写 128–\(draft.modelCapacity.selectableOutputMaximum.formatted()) tokens。旧设置未指定时按 512 tokens 显示。")
                .font(.footnote).foregroundStyle(.secondary)
            if draft.modelCapacity.outputIncludesThinking && draft.summaryOutputTokens < 8_192 {
                Text("MiniMax 摘要的思考和正文也共用这份预算；当前小预算可能被思考占满，在摘要正文前耗尽。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func numberField(_ title: String, value: Binding<Int>, field: Field, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.bold())
            TextField("tokens", value: value, format: .number.grouping(.never))
                .keyboardType(.numberPad)
                .focused($focusedField, equals: field)
                .frame(minHeight: 44)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
            if focusedField == field {
                Button("完成输入") { focusedField = nil }
                    .frame(minHeight: 44)
                    .accessibilityLabel("完成\(title)输入，收起键盘")
            }
        }
    }

    private var summaryEnabled: Binding<Bool> {
        Binding(get: { draft.summarizesContext }, set: { draft.setModelSummaryEnabled($0) })
    }

    private var summaryOutputBudget: Binding<Int> {
        Binding(get: { draft.summaryOutputTokens }, set: { draft.contextSummaryOutputTokens = $0 })
    }

    private var toolHistoryCompaction: Binding<Bool> {
        Binding(get: { draft.contextToolHistoryCompaction ?? false }, set: { draft.contextToolHistoryCompaction = $0 })
    }

    private var summaryChoices: [Int] {
        [512, 2_048, 4_096, 8_192, 16_384, 32_768].filter { $0 <= draft.modelCapacity.selectableOutputMaximum }
    }

    private func tokenDescription(_ value: Int?) -> String {
        value.map { "\($0.formatted()) tokens" } ?? "未知"
    }
}
