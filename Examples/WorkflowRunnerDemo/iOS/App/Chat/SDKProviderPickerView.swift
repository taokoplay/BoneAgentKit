import SwiftUI

struct SDKProviderPickerView: View {
    @Binding var selection: DemoChatProvider
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var providers: [DemoChatProvider] {
        DemoChatProvider.allCases.filter { provider in
            search.isEmpty || provider.title.localizedCaseInsensitiveContains(search)
                || provider.catalogIdent.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(providers) { provider in
                    Button {
                        selection = provider
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            SDKProviderIcon(provider: provider, size: 28)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.title).font(.headline).foregroundStyle(.primary)
                                Text(provider.defaultBaseURL.isEmpty ? "自定义接口地址" : provider.defaultBaseURL)
                                    .font(.footnote).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            if provider.catalogIdent == selection.catalogIdent {
                                Image(systemName: "checkmark").foregroundStyle(Color("AccentColor"))
                                    .accessibilityLabel("已选择")
                            }
                        }
                        .frame(minHeight: 52)
                        .contentShape(.rect)
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(provider.catalogIdent == selection.catalogIdent ? "已选择" : "")
                    .accessibilityIdentifier("sdkProvider_\(provider.catalogIdent)")
                }
            } header: { Text("SDK 聊天渠道 · \(DemoChatProvider.allCases.count)") }
              footer: { Text("名称、顺序、默认接口和图标均来自 SDK 目录。选择渠道会应用该渠道当前的默认配置。") }
            if providers.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .navigationTitle("选择服务商")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索服务商")
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
