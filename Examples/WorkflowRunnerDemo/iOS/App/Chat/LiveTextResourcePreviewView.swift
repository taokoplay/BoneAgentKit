import SwiftUI
import BoneAgentKit

@MainActor
struct LiveTextResourcePreviewView: View {
    let resource: DemoImportedTextResource
    private let readPage: @MainActor (Int) async throws -> BoneToolTextResourcePage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var page: BoneToolTextResourcePage?
    @State private var pageStartOffsets = [0]
    @State private var pageIndex = 0
    @State private var pendingRequest: PageRequest? = .init(offset: 0, index: 0)
    @State private var retryRequest: PageRequest?
    @State private var notice: ReadNotice?

    private struct PageRequest: Equatable, Sendable {
        let id = UUID()
        let offset: Int
        let index: Int
    }

    private enum ReadNotice {
        case failed
        case cancelled

        var message: String {
            switch self {
            case .failed: "无法读取本地文本。请重试。"
            case .cancelled: "已取消读取。"
            }
        }
    }

    init(
        resource: DemoImportedTextResource,
        readPage: @escaping @MainActor (Int) async throws -> BoneToolTextResourcePage
    ) {
        self.resource = resource
        self.readPage = readPage
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(resource.name)
                            .font(.headline)
                            .textSelection(.enabled)
                            .accessibilityAddTraits(.isHeader)
                        Text("共 \(resource.utf8ByteCount.formatted()) 个 UTF-8 字节")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    if let page {
                        if page.text.isEmpty {
                            Text("这份材料为空。")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: page.text)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("localTextPreviewContent")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(LabStyle.pageInset)
                .id("localTextPreviewTop")
            }
            .onChange(of: page?.offset) { _, _ in
                proxy.scrollTo("localTextPreviewTop", anchor: .top)
            }
        }
        .background(LabStyle.canvas)
        .navigationTitle("文本预览")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    pendingRequest = nil
                    dismiss()
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityIdentifier("dismissTextResourcePreview")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { pageControls }
        .task(id: pendingRequest) { [request = pendingRequest] in
            guard let request else { return }
            await loadPage(request)
        }
        .onChange(of: resource.preview.reference) { _, _ in
            page = nil
            pageStartOffsets = [0]
            pageIndex = 0
            beginRead(offset: 0, index: 0)
        }
        .onDisappear { pendingRequest = nil }
        .accessibilityIdentifier("localTextResourcePreview")
    }

    private var pageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let pendingRequest {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在读取第 \(pendingRequest.index + 1) 页…")
                        .font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                Button(role: .cancel) {
                    cancelRead()
                } label: {
                    Text("取消读取").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cancelTextResourcePreviewRead")
            } else if let notice, let retryRequest {
                Text(notice.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("textResourcePreviewNotice")
                Button {
                    beginRead(offset: retryRequest.offset, index: retryRequest.index)
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("retryTextResourcePreview")
            }
            if let page {
                Text("第 \(pageIndex + 1) 页\(page.nextOffset == nil ? " · 已到末尾" : "")")
                    .font(.subheadline)
                Text("UTF-8 偏移 \(page.offset.formatted()) · 本页 \(page.text.utf8.count.formatted()) 字节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    Button {
                        guard pendingRequest == nil, pageIndex > 0 else { return }
                        beginRead(offset: pageStartOffsets[pageIndex - 1], index: pageIndex - 1)
                    } label: {
                        Label("上一页", systemImage: "chevron.left")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(pendingRequest != nil || pageIndex == 0)
                    .accessibilityIdentifier("previousTextResourcePreviewPage")
                    Button {
                        guard pendingRequest == nil, let nextOffset = page.nextOffset else { return }
                        beginRead(offset: nextOffset, index: pageIndex + 1)
                    } label: {
                        Label("下一页", systemImage: "chevron.right")
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .disabled(pendingRequest != nil || page.nextOffset == nil)
                    .accessibilityIdentifier("nextTextResourcePreviewPage")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LabStyle.pageInset)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func beginRead(offset: Int, index: Int) {
        notice = nil
        retryRequest = nil
        pendingRequest = .init(offset: offset, index: index)
    }

    private func cancelRead() {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        retryRequest = request
        notice = .cancelled
    }

    private func loadPage(_ request: PageRequest) async {
        do {
            try Task.checkCancellation()
            let received = try await readPage(request.offset)
            try Task.checkCancellation()
            guard pendingRequest == request else { return }
            guard received.reference == resource.preview.reference,
                  received.offset == request.offset,
                  received.text.utf8.count <= 16 * 1_024,
                  (0...pageStartOffsets.count).contains(request.index) else {
                throw BoneToolTextResourceError.invalidPage
            }
            // Keep only page starts and the current body; never accumulate file contents.
            pageStartOffsets = Array(pageStartOffsets.prefix(request.index)) + [received.offset]
            pageIndex = request.index
            page = received
            pendingRequest = nil
        } catch {
            guard pendingRequest == request else { return }
            pendingRequest = nil
            retryRequest = request
            notice = Task.isCancelled || error is CancellationError ? .cancelled : .failed
        }
    }
}
