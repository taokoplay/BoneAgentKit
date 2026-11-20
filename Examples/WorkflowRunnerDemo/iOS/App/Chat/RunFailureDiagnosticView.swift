import SwiftUI

struct RunFailureDiagnosticView: View {
    let diagnostic: DemoRunFailureDiagnostic
    var title = "诊断信息"

    var body: some View {
        DisclosureGroup(title) {
            VStack(alignment: .leading, spacing: 12) {
                Text(diagnostic.message).font(.subheadline)
                Text(diagnostic.text).font(.caption.monospaced())
                    .foregroundStyle(.secondary).textSelection(.enabled)
                ShareLink("分享诊断", item: diagnostic.text)
                    .frame(minHeight: 44).buttonStyle(.borderless)
                    .accessibilityIdentifier("shareRunDiagnostic")
                Text("仅含固定错误码与计数，不含问题、网址、材料正文或 Key。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
        .font(.subheadline)
        .accessibilityIdentifier("runFailureDiagnostic")
    }
}
