import SwiftUI

/// Inline progress and structured-result summary. Automatic search never presents the renderer.
struct LiveBrowserSearchView: View {
    let model: LiveBrowserSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let active = model.active {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在搜索百度公开结果").font(.subheadline.weight(.semibold))
                    Spacer(minLength: 4)
                    Button("停止", action: model.cancel).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("stopBaiduAnswerRead")
                }
                Text(active.query).font(.subheadline).textSelection(.enabled)
                Text("后台读取 · 最长 28 秒")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let snapshot = model.lastSnapshot {
                Label("已读取百度公开结果", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                Text("读取于 \(snapshot.observedAt.formatted(date: .abbreviated, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = URL(string: snapshot.sourceURL) {
                    Link(snapshot.title, destination: url).font(.subheadline).frame(minHeight: 44)
                }
                DisclosureGroup("查看搜索结果摘要") {
                    Text((try? snapshot.output().results.first?.snippet) ?? "")
                        .font(.footnote).textSelection(.enabled)
                }
            } else if let message = model.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("baiduAnswerReader")
    }
}
