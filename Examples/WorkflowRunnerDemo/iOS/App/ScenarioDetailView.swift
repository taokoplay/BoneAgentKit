import SwiftUI

struct ScenarioDetailView: View {
    let scenario: DemoScenarioID
    let model: ScenarioLabModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(scenario.title, systemImage: scenario.symbol)
                        .font(.headline)
                        .foregroundStyle(Color("AccentColor"))
                    Text(scenario.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("预期结果")
                        .font(.subheadline.weight(.medium))
                    Text(scenario.expectation)
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }

            if model.running == scenario {
                Section("实际结果") {
                    ProgressView("正在执行并检查证据…")
                        .padding(.vertical, 8)
                }
            }

            if let error = model.errors[scenario] {
                Section("实际结果") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("验证未通过", systemImage: "exclamationmark.triangle.fill")
                            .font(.title3.bold())
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.subheadline)
                            .textSelection(.enabled)
                        Text("重新运行此场景，复查实际结果与预期是否一致。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            if let result = model.results[scenario] {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("验证通过", systemImage: "checkmark.seal.fill")
                            .font(.title3.bold())
                            .foregroundStyle(Color("AccentColor"))
                            .accessibilityIdentifier("scenarioPassed")
                        Text("实际状态符合本场景预期。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    ForEach(result.metrics) { metric in
                        LabeledContent {
                            Text(metric.value)
                                .monospacedDigit()
                                .textSelection(.enabled)
                        } label: {
                            Text(metric.name)
                        }
                    }
                } header: {
                    Text("实际结果")
                }

                Section {
                    DisclosureGroup("执行证据 · \(result.evidence.count) 项") {
                        ForEach(Array(result.evidence.enumerated()), id: \.offset) { index, evidence in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("证据 \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(evidence)
                                    .font(.subheadline.monospaced())
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            } else if model.running != scenario && model.errors[scenario] == nil {
                Section {
                    ContentUnavailableView("等待第一次运行", systemImage: "play.circle", description: Text("运行后显示实际请求、工具与检查点结果。"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("场景详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let result = model.results[scenario] {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: result.report) {
                        Label("分享测试报告", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await model.run(scenario) }
            } label: {
                Label {
                    Text(runButtonTitle)
                } icon: {
                    if model.isBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(LabStyle.onAccent)
            .controlSize(.large)
            .frame(minHeight: 44)
            .disabled(model.isBusy)
            .accessibilityIdentifier("runScenario")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var runButtonTitle: String {
        if model.running == scenario { return "正在验证场景…" }
        if model.isBusy { return "其他场景运行中…" }
        if model.results[scenario] != nil || model.errors[scenario] != nil { return "重新运行" }
        return "运行此场景"
    }
}
