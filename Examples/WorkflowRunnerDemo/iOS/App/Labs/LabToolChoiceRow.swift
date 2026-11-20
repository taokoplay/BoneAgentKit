import SwiftUI
import BoneAgentTools

struct LabToolChoiceRow: View {
    let workspace: LabWorkspaceModel
    @Bindable var choice: LabToolChoice
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var guide: DemoToolUsage { DemoToolUsage.guide(for: choice.group) }
    private var isApplied: Bool {
        DemoLabToolPlan(settings: workspace.store.settings).groups.contains(choice.group)
    }
    private var selectionTitle: String {
        if choice.isSelected {
            if requirement != nil { return "已选 · 待配置" }
            return isApplied ? "已选" : "已选 · 待应用"
        }
        return isApplied ? "未选 · 待应用" : "未选"
    }
    private var requirement: DemoLabRequirement? {
        DemoLabToolPlan(groups: [choice.group]).requirements(
            settings: workspace.store.settings,
            hasModelKey: workspace.store.hasKey,
            hasSearchKey: workspace.store.hasSearchKey,
            hasDeepSeekSearchKey: workspace.store.hasDeepSeekSearchKey
        ).first { requirement in
            switch requirement.kind {
            case .webHosts: choice.group == .webFetch
            case .searchKey: choice.group == .webSearch
            default: false
            }
        }
    }
    private var isNetworkTool: Bool { choice.group == .webFetch || choice.group == .webSearch }
    private var actionLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(spacing: LabStyle.itemSpacing))
    }
    private var toggleIdentifier: String {
        switch choice.group {
        case .calculator: "calculatorToggle"
        case .dateTime: "dateTimeToggle"
        case .resources: "resourcesToggle"
        case .webFetch: "webFetchToggle"
        case .webSearch: "webSearchToggle"
        case .askUser: "askUserToggle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $choice.isSelected) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(choice.group == .webSearch ? "模型自动搜索" : choice.group.title)
                        Text(selectionTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(choice.isSelected != isApplied ? LabStyle.accent : Color.secondary)
                    }
                } icon: {
                    Image(systemName: guide.symbol)
                }
            }
            .toggleStyle(.switch)
            .frame(minHeight: 44)
            .disabled(!workspace.canEdit)
            .accessibilityIdentifier(toggleIdentifier)
            .onChange(of: choice.isSelected) { _, _ in workspace.selectionChanged() }

            actionLayout {
                Button("用法", systemImage: "info.circle") {
                    workspace.openConfiguration(.guide(choice.group))
                }
                .frame(minWidth: 44, minHeight: 44)
                .disabled(!workspace.canEdit)
                .accessibilityIdentifier("labToolGuide_\(choice.group.id)")

                if isNetworkTool {
                    Button(choice.group == .webSearch ? "搜索设置" : "网站设置", systemImage: "network") {
                        workspace.openConfiguration(.network)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!workspace.canEdit)
                    .accessibilityIdentifier("labToolSetup_\(choice.group.id)")
                }
            }
        }
        .padding(.vertical, 4)
        .buttonStyle(.borderless)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("labTool_\(choice.group.rawValue)")
    }
}
