import SwiftUI

struct LabValidationResultView: View {
    let model: LiveValidationModel
    let isUITesting: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if isUITesting {
                Label("界面测试数据 · 未联网", systemImage: "wifi.slash")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let report = model.report {
                Section {
                    Label(report.verdict.title, systemImage: verdictSymbol(report.verdict))
                        .font(.title3.bold())
                        .foregroundStyle(report.verdict == .passed ? LabStyle.accent : Color.primary)
                        .accessibilityIdentifier("validationVerdict")
                    Text(report.request.kind.title).font(.headline)
                    Text("\(report.request.settings.provider.title) · \(report.request.settings.modelID)")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .accessibilityIdentifier("validationResultModel")
                    ForEach(report.checks) { check in
                        Label(check.title, systemImage: check.passed ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(check.passed ? Color.primary : Color.red)
                    }
                    if report.verdict == .needsReview {
                        Text("未填写检查词，请对照助手说明检查回答。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("本次检查") }
                  footer: { Text("结果只对应本次请求和上方模型；更改设置后可返回重新测试。") }

                Section("模型回答") {
                    Text(report.finalText).textSelection(.enabled)
                        .accessibilityIdentifier("validationReply")
                }
                Section("实际调用") {
                    LabeledContent("模型请求", value: "\(report.statistics.stepCount)")
                        .accessibilityIdentifier("validationModelCalls")
                    LabeledContent("工具执行", value: "\(report.statistics.toolCallCount)")
                        .accessibilityIdentifier("validationToolCalls")
                    LabeledContent("总耗时", value: "\(report.elapsedSeconds.formatted(.number.precision(.fractionLength(2)))) 秒")
                    if let usage = report.statistics.tokens.knownUsage {
                        LabeledContent("输入 / 输出 Token", value: "\(usage.inputTokens) / \(usage.outputTokens)")
                        Text("服务商用量上报 \(report.statistics.tokens.reportedResponseCount) / \(report.statistics.tokens.requestCount) 次。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("服务商未提供 Token 用量。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    DisclosureGroup("查看实际请求") {
                        Text("助手说明").font(.subheadline.bold())
                        Text(report.request.settings.systemPrompt.isEmpty ? "未设置" : report.request.settings.systemPrompt)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("validationSystemPrompt")
                        ForEach(Array(report.inputs.enumerated()), id: \.offset) { index, input in
                            Text("第 \(index + 1) 轮任务").font(.subheadline.bold())
                            Text(input).textSelection(.enabled)
                            if report.replies.indices.contains(index) {
                                Text("回答").font(.subheadline.bold())
                                Text(report.replies[index].text).textSelection(.enabled)
                            }
                        }
                        let values = report.replies.flatMap(\.calculatorValues)
                        if !values.isEmpty {
                            Text("计算器实际结果：" + values.map { $0.formatted() }.joined(separator: "、"))
                                .accessibilityIdentifier("validationCalculatorEvidence")
                        }
                    }
                    .accessibilityIdentifier("validationRequestDetails")
                }
            } else if let error = model.errorMessage {
                Section("测试未完成") {
                    Label(error, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red).accessibilityIdentifier("validationError")
                    Text("任务已保留，返回后可检查设置并重新运行。")
                        .foregroundStyle(.secondary)
                }
            } else if model.isRunning {
                ProgressView(model.statusTitle)
            } else {
                Text("从实验室选择一个测试任务后开始。")
            }
            Button("返回实验室", systemImage: "arrow.uturn.backward") { dismiss() }
                .frame(minHeight: 44)
                .accessibilityIdentifier("returnFromValidation")
        }
        .navigationTitle("测试结果")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .toolbar {
            if let report = model.report {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: report.text) { Label("分享结果", systemImage: "square.and.arrow.up") }
                        .accessibilityIdentifier("shareValidationResult")
                }
            }
        }
    }

    private func verdictSymbol(_ value: DemoValidationVerdict) -> String {
        switch value {
        case .passed: "checkmark.seal"
        case .failed: "xmark.circle"
        case .needsReview: "eye"
        }
    }
}
