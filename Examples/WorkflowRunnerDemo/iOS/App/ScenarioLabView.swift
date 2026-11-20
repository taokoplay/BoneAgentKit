import SwiftUI

struct ScenarioLabView: View {
    let model: ScenarioLabModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("离线验证 · 无需 API Key", systemImage: "wifi.slash")
                        .font(.subheadline.weight(.medium))
                    Text("使用脚本模型验证 Agent、工具与状态机，不使用对话的模型和工具配置。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.summary)
                        .font(.title2.bold())
                        .monospacedDigit()
                        .accessibilityIdentifier("scenarioSummary")

                    ProgressView(value: Double(model.passedCount), total: Double(DemoScenarioID.allCases.count)) {
                        Text("通过进度")
                            .font(.subheadline)
                    } currentValueLabel: {
                        Text("\(model.passedCount) / \(DemoScenarioID.allCases.count)")
                            .monospacedDigit()
                    }
                    .accessibilityLabel("场景通过进度")
                    .accessibilityValue("已通过 \(model.passedCount) 项，共 \(DemoScenarioID.allCases.count) 项")

                    if let scenario = model.running {
                        Text("当前：\(scenario.title)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await model.runAll() }
                    } label: {
                        Label {
                            Text(model.isBusy ? "正在验证场景…" : "全部运行")
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
                    .accessibilityIdentifier("runAllScenarios")
                }
                .padding(.vertical, 8)
            }

            Section("\(DemoScenarioID.allCases.count) 个场景") {
                ForEach(DemoScenarioID.allCases) { scenario in
                    NavigationLink {
                        ScenarioDetailView(scenario: scenario, model: model)
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: scenario.symbol)
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Color("AccentColor"))
                                .frame(width: 44, height: 44)
                                .background(Color("AccentColor").opacity(0.08), in: .rect(cornerRadius: 12))
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(scenario.title)
                                    .font(.headline)
                                Text(scenario.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                status(scenario)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .accessibilityIdentifier("scenario_\(scenario.rawValue)")
                }
            }

            Section {
                DisclosureGroup("验证范围") {
                    Label("不产生模型费用", systemImage: "wifi.slash")
                    Label("调用真实 SDK 执行链", systemImage: "point.3.connected.trianglepath.dotted")
                    Text("每次运行创建独立内存状态。预期内的拒绝也是通过；场景详情会展示实际指标与执行证据。")
                    Text("模型响应由脚本给出。这能验证执行与恢复机制，不能证明真实模型的回答质量，也不是跨进程恢复验收。")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("场景测试")
        .navigationBarTitleDisplayMode(.large)
    }

    @ViewBuilder
    private func status(_ scenario: DemoScenarioID) -> some View {
        if model.running == scenario {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text("运行中")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if model.results[scenario] != nil {
            Label("通过", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color("AccentColor"))
        } else if model.errors[scenario] != nil {
            Label("失败", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        } else {
            Label("待运行", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
