import SwiftUI

struct PromptLabView: View {
    @State private var draft = PromptLabDraft()
    @State private var result: PromptLabResult?
    @State private var showingResult = false
    @State private var error: String?
    @State private var running = false
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Label("合成模型 · 离线验证", systemImage: "text.alignleft")
                        .font(.subheadline.weight(.medium))
                    Text("本页单独验证 Prompt 组装，不会修改对话的系统指令；真实工具任务在实验室运行。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("基础指令", selection: $draft.choice) {
                    ForEach(PromptBaseChoice.allCases) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("baseChoice")

                switch draft.choice {
                case .inherit:
                    editor("默认基础指令", text: $draft.base, identifier: "baseEditor")
                case .replace:
                    editor("替换为", text: $draft.replacement, identifier: "replacementEditor")
                case .clear:
                    Text("仅清空基础指令；运行指引和下方追加说明仍会保留。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                editor("追加说明", text: $draft.append, identifier: "appendEditor")
            } header: {
                Text("System 指令")
            } footer: {
                Text("替换或清空只影响基础指令。空文本的槽位不会加入组装。")
            }
            .disabled(running)

            Section {
                editor("本次运行事实", text: $draft.fact, identifier: "factEditor")
            } header: {
                Text("User 数据")
            } footer: {
                Text("运行事实放入当前用户请求，不进入 System，也不授予工具权限。")
            }
            .disabled(running)

            if let error {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("组装或执行未通过", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.subheadline)
                            .textSelection(.enabled)
                        Text("检查输入内容；如提示容量不足，请缩短文本，再点“组装并测试”重试。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("Prompt 实验")
        .navigationBarTitleDisplayMode(.large)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editing = false }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await composeAndRun() }
            } label: {
                Label {
                    Text(running ? "正在组装并测试…" : "组装并测试")
                } icon: {
                    if running {
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
            .disabled(running)
            .accessibilityIdentifier("composePrompt")
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .navigationDestination(isPresented: $showingResult) {
            if let result {
                PromptResultView(result: result)
            }
        }
        .onChange(of: draft) { _, _ in
            result = nil
            error = nil
            showingResult = false
        }
    }

    private func editor(_ title: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
            TextField(title, text: text, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.plain)
                .focused($editing)
                .accessibilityLabel(title)
                .accessibilityIdentifier(identifier)
        }
        .padding(.vertical, 4)
    }

    @MainActor
    private func composeAndRun() async {
        guard !running else { return }
        editing = false
        running = true
        error = nil
        result = nil
        defer { running = false }
        do {
            let sections = { (id: String, text: String) -> [DemoPromptSection] in
                text.isEmpty ? [] : [.init(id: id, text: text)]
            }
            let baseOverride: DemoPromptBaseOverride
            switch draft.choice {
            case .inherit: baseOverride = .inherit
            case .replace: baseOverride = .replace(sections("host.replacement", draft.replacement))
            case .clear: baseOverride = .replace([])
            }
            let profile = DemoPromptProfile(
                defaultBase: sections("host.base", draft.base), baseOverride: baseOverride,
                runtimeGuidance: [.init(id: "runtime.mode", text: "planning：只能调用公开只读工具 demo.read。")],
                append: sections("host.append", draft.append))
            let facts: [DemoPromptFact] = draft.fact.isEmpty ? [] : [.init(id: "runtime.fact", sourceID: "phone.input", value: draft.fact)]
            let composition = try DemoPromptCompositor().compose(profile: profile, facts: facts)
            let messages = composition.systemMessages + [
                .init(role: .user, content: "请确认收到本次验证请求。\n" + (composition.runtimeDataText ?? ""))]
            let fixture = try DemoFixture(script: [DemoFixture.finish("Synthetic request received")], messages: messages)
            let report = try await fixture.runner().start(runID: .init("phone-prompt"), plan: demoPlan(),
                                                          mode: .planning, input: DemoFixture.input)
            let requests = await fixture.engine.receivedRequests()
            try demoCheck(report.outcome == .completed && requests.count == 1, "prompt execution")
            try demoCheck(requests[0].messages == messages, "actual messages match composition")
            result = PromptLabResult(composition: composition, requestCount: requests.count,
                                     visibleToolIDs: requests[0].availableTools.map(\.id),
                                     userText: requests[0].messages.last?.content ?? "")
            showingResult = true
        } catch { self.error = "本次组装未通过：\(String(describing: error))" }
    }
}
