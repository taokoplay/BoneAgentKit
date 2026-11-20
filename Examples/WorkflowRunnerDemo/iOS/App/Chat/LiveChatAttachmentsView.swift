import SwiftUI
import UIKit
import BoneAgentTools

struct LiveChatAttachmentsView: View {
    let images: [DemoPreparedChatImage]
    let resources: [DemoImportedTextResource]
    /// 当前消息或草稿中的统一文件资源附件。
    let fileResources: [DemoImportedFileResource]
    var removeImage: ((String) -> Void)?
    var removeResource: ((String) -> Void)?
    var removeFileResource: ((String) -> Void)?
    var onPreviewResource: (DemoImportedTextResource) -> Void = { _ in }
    /// 统一文件资源的本地预览回调。
    var onPreviewFileResource: (DemoImportedFileResource) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .center, spacing: 12) {
                ForEach(images) { image in
                    HStack(spacing: 8) {
                        if let preview = UIImage(data: image.previewData) {
                            Image(uiImage: preview).resizable().scaledToFill()
                                .frame(width: 60, height: 60).clipped()
                                .clipShape(.rect(cornerRadius: 8))
                                .accessibilityLabel("图片 \(image.width) × \(image.height)")
                        }
                        if let removeImage {
                            Button("移除图片", systemImage: "xmark.circle.fill") { removeImage(image.id) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("removeChatImage")
                        }
                    }
                    .padding(8).background(LabStyle.inset, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("chatImageAttachment")
                }
                ForEach(resources) { resource in
                    HStack(spacing: 8) {
                        Button { onPreviewResource(resource) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text").foregroundStyle(LabStyle.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(resource.name).font(.subheadline).lineLimit(2)
                                    Text(resource.utf8ByteCount.formatted(.byteCount(style: .file)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 180, alignment: .leading)
                            }
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("预览 \(resource.name)")
                        .accessibilityValue(resource.utf8ByteCount.formatted(.byteCount(style: .file)))
                        .accessibilityHint("查看本地文本，可逐页阅读")
                        .accessibilityIdentifier("previewChatResource")
                        if let removeResource {
                            Button("移除 \(resource.name)", systemImage: "xmark.circle.fill") { removeResource(resource.id) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("removeChatResource")
                        }
                    }
                    .padding(12).background(LabStyle.inset, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("chatTextAttachment")
                }
                ForEach(fileResources) { resource in
                    HStack(spacing: 8) {
                        Button { onPreviewFileResource(resource) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: symbol(for: resource.kind)).foregroundStyle(LabStyle.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(resource.name).font(.subheadline).lineLimit(2)
                                    Text("\(resource.kind.title) · \(resource.byteCount.formatted(.byteCount(style: .file)))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: 210, alignment: .leading)
                            }
                            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("预览 \(resource.name)")
                        .accessibilityValue("\(resource.kind.title)，\(resource.byteCount.formatted(.byteCount(style: .file)))")
                        .accessibilityHint("查看文件格式和有界内容")
                        .accessibilityIdentifier("previewChatFileResource")
                        if let removeFileResource {
                            Button("移除 \(resource.name)", systemImage: "xmark.circle.fill") { removeFileResource(resource.id) }
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                .accessibilityIdentifier("removeChatFileResource")
                        }
                    }
                    .padding(12).background(LabStyle.inset, in: .rect(cornerRadius: 12))
                    .accessibilityIdentifier("chatFileAttachment")
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// 返回统一文件资源的稳定展示图标。
    private func symbol(for kind: BoneFileResourceKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .pdf: "doc.richtext"
        case .officeOpenXML: "doc.text.image"
        case .archive: "archivebox"
        case .binary: "doc.viewfinder"
        }
    }
}

private extension BoneFileResourceKind {
    /// 返回统一文件资源类型的中文标签。
    var title: String {
        switch self {
        case .text: "文本"
        case .pdf: "PDF"
        case .officeOpenXML: "Office"
        case .archive: "压缩包"
        case .binary: "二进制"
        }
    }
}
