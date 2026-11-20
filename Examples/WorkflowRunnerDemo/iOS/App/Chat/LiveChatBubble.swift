import SwiftUI
import UIKit

struct LiveChatBubble: View {
    let message: LiveChatMessage
    let provider: DemoChatProvider
    let images: [DemoPreparedChatImage]
    let resources: [DemoImportedTextResource]
    /// 当前消息中的统一文件资源附件。
    let fileResources: [DemoImportedFileResource]
    var onPreviewResource: (DemoImportedTextResource) -> Void = { _ in }
    var onPreviewFileResource: (DemoImportedFileResource) -> Void = { _ in }
    @State private var copied = false

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
            if message.role == .assistant {
                HStack(spacing: 8) {
                    SDKProviderIcon(provider: provider, size: 20)
                    Text(provider.title).font(.subheadline.bold())
                }
            }
            if !images.isEmpty || !resources.isEmpty || !fileResources.isEmpty {
                LiveChatAttachmentsView(images: images, resources: resources, fileResources: fileResources,
                    onPreviewResource: onPreviewResource, onPreviewFileResource: onPreviewFileResource)
            }
            Text(message.text)
                .font(.body)
                .textSelection(.enabled)
                .padding(message.role == .user ? 16 : 0)
                .background {
                    if message.role == .user {
                        RoundedRectangle(cornerRadius: LabStyle.cardRadius).fill(LabStyle.inset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
                .accessibilityLabel(message.role == .user ? "你：\(message.text.isEmpty ? "附件" : message.text)" : message.text)
                .accessibilityIdentifier(message.role == .assistant ? "assistantMessage" : "userMessage")
            if message.role == .assistant {
                HStack(alignment: .center, spacing: 8) {
                    if let detail = message.detail {
                        Text(detail).font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button(copied ? "已复制" : "复制回复", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = message.text
                        copied = true
                    }
                    .labelStyle(.iconOnly)
                    .font(.subheadline)
                    .foregroundStyle(copied ? LabStyle.accent : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("copyReply")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .contextMenu {
            Button("复制", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = message.text
                copied = true
            }
            ShareLink(item: message.text) { Label("分享", systemImage: "square.and.arrow.up") }
        }
        .sensoryFeedback(.success, trigger: copied)
    }
}
