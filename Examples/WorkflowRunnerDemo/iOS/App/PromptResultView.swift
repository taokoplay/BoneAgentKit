import SwiftUI

struct PromptResultView: View {
    let result: PromptLabResult

    var body: some View {
        List {
            Section {
                Label("组装与执行通过", systemImage: "checkmark.seal.fill")
                    .font(.title3.bold())
                    .foregroundStyle(Color("AccentColor"))
                    .padding(.vertical, 4)
                    .accessibilityIdentifier("promptPassed")

                metric("System 字节", value: "\(result.composition.systemUTF8ByteCount)")
                metric("User 数据字节", value: "\(result.composition.runtimeUTF8ByteCount)")
                metric("模型请求", value: "\(result.requestCount)")
                metric("可见工具", value: result.visibleToolIDs.isEmpty ? "无" : result.visibleToolIDs.joined(separator: ", "))
            } header: {
                Text("实际结果 · UTF-8")
            } footer: {
                Text("模型响应由脚本给出。本次验证消息组装与执行路径，不验证模型是否理解了这些指令。")
            }

            Section {
                DisclosureGroup("System 生效顺序") {
                    ForEach(Array(result.composition.sectionIDs.enumerated()), id: \.offset) { index, id in
                        LabeledContent("\(index + 1)", value: id)
                            .font(.subheadline.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }

            Section("实际 System") {
                Text(result.systemText.isEmpty ? "（未生成 System 消息）" : result.systemText)
                    .font(.subheadline.monospaced())
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("systemPreview")
            }

            Section {
                Text(result.userText)
                    .font(.subheadline.monospaced())
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("userPreview")
            } header: {
                Text("实际 User")
            } footer: {
                Text("运行事实保留在 User 的数据部分，不进入 System，也不授予工具权限。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("组装结果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: result.report) {
                    Label("分享组装结果", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func metric(_ title: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        } label: {
            Text(title)
        }
    }
}
