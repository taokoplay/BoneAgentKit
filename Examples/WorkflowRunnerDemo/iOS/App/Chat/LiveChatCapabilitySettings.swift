import SwiftUI

struct LiveChatCapabilitySettings: View {
    @Binding var draft: DemoLiveChatSettings

    var body: some View {
        Section {
            LiveModelBudgetFields(draft: $draft)
        } header: { Text("推理与上下文") }
          footer: {
            Text("流式不可用时可手动关闭，不会自动重发。")
        }
        Section {
            NavigationLink {
                SDKVisionSettingsView(draft: $draft)
            } label: {
                LabeledContent("图片理解", value: draft.visionPolicy == .disabled ? "未配置" : "已配置规则")
            }
            .accessibilityIdentifier("visionSettings")
        } footer: {
            Text("图片由 SDK 在本机预处理，并在发送时按具体模型校验容量和读取权限。")
        }
        Section {
            Toggle("本机保存已完成会话", isOn: $draft.preservesConversation)
                .accessibilityIdentifier("persistConversationToggle")
        } header: { Text("会话") }
          footer: {
            Text("超过 512 KiB 的附件仅在关闭此开关时可用，临时快照退出后释放，不会存档。关闭开关或变更配置会清理旧存档。保存内容包含聊天正文、工具历史和小附件，使用 App 私有存储并排除系统备份。恢复只加载已完成历史，不自动恢复或重发中断请求；统计从本次启动重新观测。")
        }
    }
}
