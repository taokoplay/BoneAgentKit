import SwiftUI
import BoneAgentKit

struct LiveChatStatisticsView: View {
    let model: LiveChatModel
    let settings: DemoLiveChatSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("运行状态") {
                LabeledContent("状态", value: model.isSending ? model.statusTitle : "当前空闲")
                if let step = model.currentStatus?.step { LabeledContent("最近推理步骤", value: "\(step)") }
                Text("状态来自 SDK 事件。只有服务商明确报告思考活动时才显示思考中。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            capacitySection
            Section("当前上下文") {
                if let context = model.tokenSnapshot?.context {
                    value("输入占用", context.inputTokens)
                    value("可用输入容量", context.availableInputTokens)
                    value("预留回复", context.reservedOutputTokens)
                    value("图片数", context.imageCount)
                    LabeledContent("计数来源", value: source(context.source))
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("contextTokenSource")
                    if let utilization = context.utilization {
                        LabeledContent("输入容量占比", value: utilization.formatted(.percent.precision(.fractionLength(1))))
                        ProgressView(value: min(max(utilization, 0), 1)).tint(LabStyle.accent)
                    }
                    if let before = context.inputTokensBeforeCompaction { value("整理前输入", before) }
                    value("距离整理阈值", context.tokensUntilCompaction)
                } else {
                    Text("发送消息后显示 SDK 的上下文测量。")
                        .foregroundStyle(.secondary)
                }
                Text(settings.managesContext
                     ? "Host 窗口上限 \(settings.contextWindowTokens) Token，与 SDK 已知模型限制取交集；85% 触发整理，目标 65%。这不是服务商官方容量声明。"
                     : "自动上下文整理已关闭。")
                    .font(.footnote).foregroundStyle(.secondary)
                if settings.summarizesContext {
                    Text("允许整理时额外调用一次模型生成摘要，输出预算 \(settings.summaryOutputTokens) Token。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            compactionSection
            if let snapshot = model.tokenSnapshot {
                Section(model.isSending ? "本轮用量 · 进行中" : "最近一轮用量") {
                    usage(snapshot.total)
                    if let provisional = snapshot.latestRequest?.provisionalUsage,
                       snapshot.latestRequest?.state == .inFlight {
                        LabeledContent("暂报输入", value: "\(provisional.inputTokens)")
                        LabeledContent("暂报输出", value: "\(provisional.outputTokens)")
                        Text("暂报值不计入正式合计。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section(model.isSending ? "此前完成的运行统计" : "本次打开后的运行统计") {
                let statistics = model.statistics
                LabeledContent("轮数 / 成功", value: "\(statistics.roundCount) / \(statistics.successfulRoundCount)")
                LabeledContent("推理 / 工具调用", value: "\(statistics.stepCount) / \(statistics.toolCallCount)")
                LabeledContent("摘要调用", value: "\(statistics.summaryCallCount)")
                usage(statistics.tokens)
                LabeledContent("模型耗时", value: seconds(statistics.modelDurationSeconds))
                LabeledContent("工具耗时", value: seconds(statistics.toolDurationSeconds))
                LabeledContent("平均首字延迟", value: seconds(statistics.averageTimeToFirstTokenSeconds))
                LabeledContent("输出速度", value: statistics.outputTokensPerSecond.map {
                    "\($0.formatted(.number.precision(.fractionLength(1)))) Token/s"
                } ?? "未提供")
                Text("首字样本 \(statistics.timeToFirstTokenSampleCount) · 速度样本 \(statistics.throughputSampleCount)。只有完整上报和有效实时测量才计入；测试替身不提供实时测量。")
                    .font(.footnote).foregroundStyle(.secondary)
                if !statistics.isHistoryComplete {
                    Text("恢复前的历史时延和用量未保存，当前统计不覆盖此前历史。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !model.failureHistory.isEmpty || model.diagnosticLogError != nil {
                Section("最近失败诊断 · 本机") {
                    ForEach(model.failureHistory.reversed(), id: \.id) { diagnostic in
                        RunFailureDiagnosticView(diagnostic: diagnostic,
                            title: diagnostic.occurredAt.formatted(date: .abbreviated, time: .standard))
                    }
                    if let error = model.diagnosticLogError { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    Text("最多保留 20 条固定错误码与计数，重开 App 后仍可查看。不会自动上传。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Token 用量来自服务商最终上报，包含主推理和摘要。未提供的值保持未知；与上下文占用、账户账单的口径不同。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("运行统计")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
        }
        .accessibilityIdentifier("chatStatisticsSheet")
    }

    private var capacitySection: some View {
        Section("模型容量与请求预算") {
            let capacity = settings.modelCapacity
            value("模型上下文上限", capacity.contextWindowTokens)
            value("模型最大输出", capacity.maximumOutputTokens)
            value("当前请求输出上限", settings.maximumOutputTokens)
            LabeledContent("容量来源", value: capacity.sourceTitle)
            if capacity.outputIncludesThinking {
                Text("此模型的思考与正文共用输出预算。上下文压缩不能提高单次输出上限。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Text("本轮累计输入 \(settings.runInputByteLimit.formatted(.byteCount(style: .memory)))、累计输出 \(settings.runOutputByteLimit.formatted(.byteCount(style: .memory)))，最长 120 秒。这些执行额度与模型能力分别限制请求。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var compactionSection: some View {
        Section("最近一轮自动压缩") {
            if let failure = model.contextFailure {
                Text(contextFailureMessage(failure)).foregroundStyle(.red)
                    .accessibilityIdentifier("contextCompactionFailure")
            }
            if model.contextCompactions.isEmpty {
                Text(settings.managesContext ? "本轮尚无已提交的压缩记录。低于阈值时直接发送；受保护输入装不下时会停止。" : "自动上下文压缩已关闭。")
                    .font(.subheadline).foregroundStyle(.secondary)
            } else {
                value("已提交压缩次数", model.contextCompactions.count)
                value("移除旧轮次", model.contextCompactions.reduce(0) { $0 + $1.removedTurnCount })
                value("整理旧工具交换", model.contextCompactions.reduce(0) { $0 + $1.removedToolExchangeCount })
                value("估算减少 Token", model.contextCompactions.reduce(0) { $0 + $1.estimatedRequestTokenReduction })
                LabeledContent("使用模型摘要", value: model.contextCompactions.contains(where: \.usedModelSummary) ? "是" : "否")
                LabeledContent("发生裁剪回退", value: model.contextCompactions.contains(where: \.fallbackUsed) ? "是" : "否")
            }
            Text(settings.compactsCurrentToolHistory
                ? "允许摘要当前任务的旧完整工具交换，保留当前问题及最近两组。摘要和裁剪均可能丢失细节。"
                : "当前任务的工具记录保持原文；默认仅整理旧的完整用户轮次。")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("contextCompactionSection")
    }
    private func contextFailureMessage(_ failure: BoneContextFailureDiagnostic) -> String {
        switch failure {
        case .inputExceedsBudget: "压缩未完成：当前问题或必须保留的工具记录仍超出输入预算。"
        case .summaryUnavailable: "压缩未完成：摘要没有形成可用结果。"
        case .continuationUnsupported: "当前连接无法安全重建压缩后的历史。"
        case .invalidHistory: "历史工具调用与结果不匹配，已停止压缩。"
        case .tokenCountingFailed: "未能计算输入占用，已停止压缩。"
        case .invalidConfiguration: "上下文容量或输出预留配置无效。"
        default: "上下文压缩未完成，请检查容量与本轮记录。"
        }
    }

    @ViewBuilder
    private func usage(_ totals: BoneAgentTokenTotals) -> some View {
        if let usage = totals.knownUsage {
            value("输入 Token", usage.inputTokens)
            value("输出 Token", usage.outputTokens)
            value("缓存输入", usage.cachedInputTokens)
            value("推理 Token", usage.reasoningTokens)
        } else { Text("服务商尚未提供最终 Token 用量。").foregroundStyle(.secondary) }
        Text("已上报 \(totals.reportedResponseCount) / \(totals.requestCount) 次请求\(totals.isComplete ? " · 完整" : " · 不完整或未知")")
            .font(.footnote).foregroundStyle(.secondary)
            .accessibilityIdentifier("tokenCoverage")
    }

    private func value(_ label: String, _ value: Int?) -> some View {
        LabeledContent(label, value: value.map { "\($0)" } ?? "未提供")
    }
    private func source(_ value: BoneAgentContextTokens.Source) -> String {
        switch value {
        case .estimate: "SDK 估算"
        case .tokenizer: "Tokenizer"
        case .unavailable: "未提供"
        }
    }
    private func seconds(_ value: Double?) -> String {
        value.map { "\($0.formatted(.number.precision(.fractionLength(2)))) 秒" } ?? "未提供"
    }
}

extension LiveChatModel {
    var statusTitle: String {
        guard let phase = currentStatus?.phase else { return "准备请求…" }
        switch phase {
        case .preparingInput: return "准备输入…"
        case .checkingBudget: return "检查上下文预算…"
        case .compactingContext: return "整理上下文…"
        case .summarizingContext: return "生成上下文摘要…"
        case .resolvingImages: return "处理图片…"
        case .waitingForModel: return "等待模型响应…"
        case .reasoning: return "模型思考中…"
        case .generatingResponse: return "正在生成回复…"
        case .generatingToolCall: return "模型准备工具调用…"
        case .validatingResponse: return "校验回复…"
        case .preparingTools: return "准备工具…"
        case .executingTools: return "执行工具…"
        case .processingToolResults: return "整理工具结果…"
        case .finished: return "收尾中…"
        }
    }
}
