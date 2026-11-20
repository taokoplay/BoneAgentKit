import SwiftUI

struct SDKVisionSettingsView: View {
    @Binding var draft: DemoLiveChatSettings
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    SDKProviderIcon(provider: draft.provider, size: 28)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(draft.provider.title).font(.headline)
                        Text(draft.modelID).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Picker("视觉估算规则", selection: $draft.visionPolicy) {
                    Text("关闭图片输入").tag(DemoVisionPolicy.disabled)
                    Text("OpenAI GPT-4.1 mini · Patch").tag(DemoVisionPolicy.openAI41Mini)
                    Text("当前模型的自定义规则").tag(DemoVisionPolicy.customLinear)
                }
                .accessibilityIdentifier("visionPolicyPicker")
            } footer: {
                Text("规则绑定当前协议、接口与精确模型。更换连接或模型后需重新配置；模型名称和目录条目不能代替实际支持。")
            }
            if draft.visionPolicy == .openAI41Mini {
                Section {
                    Text("使用 32 × 32 像素 Patch 和 1.62 系数；适用于精确 GPT-4.1 mini 模型。图片预处理后最长边 1024 像素。")
                        .font(.subheadline)
                    if draft.provider.kind != .openAI || !["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"].contains(draft.modelID) {
                        Label("请返回选择 OpenAI 的 GPT-4.1 mini，或配置当前模型的规则。", systemImage: "info.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if draft.visionPolicy == .customLinear {
                Section {
                    TextField("每张图片的基础 Token", value: $draft.visionTokenBase, format: .number.grouping(.never))
                        .keyboardType(.numberPad).focused($editing)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("visionBaseTokens")
                    TextField("每百万像素的 Token", value: $draft.visionTokensPerMegapixel, format: .number.grouping(.never))
                        .keyboardType(.numberPad).focused($editing)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("visionPixelTokens")
                    Text("预留 = 基础 Token + 向上取整（实际发送像素 ÷ 1000000）× 每百万像素 Token。")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("按服务商规则配置") }
                  footer: {
                    Text("两个参数都需为 1～100000。此数值为你提供的保守预算规则，不是服务商实际用量；不了解模型规则时请保持关闭。")
                }
            }
            if draft.visionPolicy != .disabled {
                Section {
                    Label("仅在点击发送后提交所选图片", systemImage: "photo")
                    Text("最多保留 6 张处理后图片；单张最多 2 MiB。图片及会话达到容量上限时需要开始新对话。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("图片理解")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: draft.visionPolicy) { _, _ in draft.bindVisionToCurrentModel() }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editing = false }
            }
        }
    }
}
