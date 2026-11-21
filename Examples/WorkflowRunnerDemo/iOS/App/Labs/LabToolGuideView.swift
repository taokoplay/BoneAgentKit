import SwiftUI
import BoneAgentTools

struct LabToolGuideView: View {
    @Bindable var workspace: LabWorkspaceModel
    let group: BoneBuiltInToolGroup

    private var guide: DemoToolUsage { DemoToolUsage.guide(for: group) }
    private var isNetworkTool: Bool { group == .webFetch || group == .webSearch }
    private var requirements: [DemoLabRequirement] {
        DemoLabToolPlan(groups: [group]).requirements(
            settings: workspace.store.settings,
            hasModelKey: workspace.store.hasKey,
            hasSearchKey: workspace.store.hasSearchKey,
            hasDeepSeekSearchKey: workspace.store.hasDeepSeekSearchKey
        )
    }
    private var preparation: String {
        switch group {
        case .calculator: "勾选计算器即可，不需要额外账号。"
        case .dateTime: "勾选工具即可，当前时间由设备提供。"
        case .resources: "先导入要使用的文本材料，再勾选资料工具。"
        case .calendar: "首次使用时系统会请求日历权限，写入操作会在执行前请求确认。"
        case .reminders: "首次使用时系统会请求提醒事项权限，写入操作会在执行前请求确认。"
        case .notifications: "首次安排通知时系统会请求通知权限，安排和取消会在执行前请求确认。"
        case .photos: "图片保存到相册时请求添加权限，并在写入前请求确认。"
        case .contacts: "首次使用时系统会请求联系人权限，写入操作会在执行前请求确认。"
        case .webFetch: "在搜索设置的「网页读取」中填写允许访问的网站，网页需提供静态 HTML 或文本。"
        case .webSearch: "百度网页问答无需搜索 Key；在搜索设置启用后，模型可读取有限公开结果。Brave、DeepSeek API 需要各自的搜索 Key。每个任务首次联网确认一次，模型用量仍按模型账户计。"
        case .askUser: "保持 App 可操作，模型提问时由你选择或输入回答。"
        }
    }
    private var taskHint: String {
        switch group {
        case .calculator: "告诉模型要计算的表达式、比例或公式。"
        case .dateTime: "说清要查询或比较的日期、时间和时区。"
        case .resources: "说清要在材料中查找什么，或请模型结合原文总结。"
        case .calendar: "说清要查询的日期，或说明要创建、修改和删除的事件。"
        case .reminders: "说清要查询、创建、完成或删除的提醒事项。"
        case .notifications: "说清通知内容、时间，或要取消的工具通知 ID。"
        case .photos: "请模型把当前对话中已登记的图片保存到相册。"
        case .contacts: "请查找联系人张三的电话，并在确认后把他的公司更新为新公司。"
        case .webFetch: "给出完整的 HTTPS 网页地址，再说明要总结或查找什么。"
        case .webSearch: "说清要查的信息，可补充来源范围和时间要求；搜索结果包含来源链接，来源网页不会自动读取。"
        case .askUser: "告诉模型需要先问清哪些问题，再继续完成任务。"
        }
    }

    var body: some View {
        Form {
            Section("这个工具做什么") {
                Label(group.title, systemImage: guide.symbol)
                    .font(.headline)
                if group == .webSearch {
                    Text("模型自动搜索可选择百度网页问答、Brave 或 DeepSeek API，供当前聊天模型使用。百度网页问答在后台读取有限公开结果，以结构化标题、来源和摘要交给模型，遇验证即停止。手动网页搜索仍由你浏览百度或必应，选取内容后加入任务。")
                } else {
                    Text(guide.purpose)
                }
            }
            .listRowBackground(LabStyle.surface)

            Section("需要什么") {
                Text(preparation)
                ForEach(requirements) { requirement in
                    if requirement.kind == .webHosts || requirement.kind == .searchKey {
                        Text(requirement.kind == .webHosts ? "待配置：允许访问的网站" : requirement.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("toolGuideRequirement_\(requirement.kind.rawValue)")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(requirement.message)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button(requirement.actionTitle, systemImage: "slider.horizontal.3") {
                                workspace.resolve(requirement)
                            }
                            .frame(minHeight: 44)
                            .disabled(!workspace.canEdit)
                            .accessibilityIdentifier("toolGuideRequirement_\(requirement.kind.rawValue)")
                        }
                    }
                }
                if isNetworkTool {
                    Button(group == .webSearch ? "搜索设置" : "网站设置", systemImage: "network") {
                        workspace.openConfiguration(.network)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .disabled(!workspace.canEdit)
                    .accessibilityIdentifier("toolGuideNetworkSettings")
                }
            }
            .listRowBackground(LabStyle.surface)

            Section {
                Text(taskHint)
                Text(guide.example)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("toolGuideExample")
                Button(workspace.selectedPlan.groups.contains(group) ? "填入这个示例" : "勾选并填入示例", systemImage: "text.badge.plus") {
                    workspace.requestExample(group)
                }
                .frame(minHeight: 44)
                .disabled(!workspace.canEdit)
                .accessibilityIdentifier("toolGuideUseExample")
            } header: {
                Text("怎样给模型任务")
            } footer: {
                Text("示例只填入任务草稿，点击运行后才发送；模型会按任务决定是否调用工具。")
            }
            .listRowBackground(LabStyle.surface)

            Section {
                DisclosureGroup("查看工具标识（可选）") {
                    ForEach(group.toolIDs, id: \.self) { toolID in
                        Text(toolID)
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("toolGuideIdentifiers")
            } footer: {
                if isNetworkTool {
                    Text("勾选会保存工具选择。首次联网时确认本次任务权限一次，同一任务内后续联网不再重复询问；下一条消息重新确认。")
                } else {
                    Text("勾选会保存工具选择。")
                }
            }
            .listRowBackground(LabStyle.surface)
        }
        .navigationTitle("调用说明")
        .navigationBarTitleDisplayMode(.inline)
        .tint(LabStyle.accent)
        .scrollContentBackground(.hidden)
        .background(LabStyle.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("完成") { workspace.configuration = nil }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("closeToolGuide")
            }
        }
        .alert("替换当前任务草稿？", isPresented: $workspace.confirmsExampleReplacement) {
            Button("替换草稿", role: .destructive) { workspace.confirmExampleReplacement() }
            Button("保留草稿", role: .cancel) { workspace.cancelExampleReplacement() }
        } message: {
            Text("填入这个示例会替换已有的任务内容。示例不会自动发送。")
        }
    }
}
