import Foundation
import BoneAgentTools

struct DemoLabToolPlan: Codable, Equatable, Sendable {
    let groups: Set<BoneBuiltInToolGroup>
    init(groups: Set<BoneBuiltInToolGroup>) { self.groups = groups }
    init(settings: DemoLiveChatSettings) {
        var groups: Set<BoneBuiltInToolGroup> = []
        if settings.enablesCalculator { groups.insert(.calculator) }
        if settings.enablesDateTime { groups.insert(.dateTime) }
        if settings.enablesCalendar { groups.insert(.calendar) }
        if settings.enablesReminders { groups.insert(.reminders) }
        if settings.enablesNotifications { groups.insert(.notifications) }
        if settings.enablesPhotos { groups.insert(.photos) }
        if settings.enablesContacts { groups.insert(.contacts) }
        if settings.enablesTextResources { groups.insert(.resources) }
        if settings.enablesWebFetch { groups.insert(.webFetch) }
        if settings.enablesWebSearch { groups.insert(.webSearch) }
        if settings.enablesAskUser { groups.insert(.askUser) }
        self.groups = groups
    }
    var orderedGroups: [BoneBuiltInToolGroup] { BoneBuiltInToolGroup.allCases.filter(groups.contains) }
    var toolCount: Int { orderedGroups.reduce(0) { $0 + $1.toolIDs.count } }
    var summary: String { orderedGroups.isEmpty ? "纯模型对话" : orderedGroups.map(\.title).joined(separator: "、") }
    func applying(to original: DemoLiveChatSettings) -> DemoLiveChatSettings {
        var settings = original
        if original.searchConfiguration == nil && original.enablesWebSearch != groups.contains(.webSearch) {
            settings.search = original.search
        }
        settings.enablesCalculator = groups.contains(.calculator)
        settings.enablesDateTime = groups.contains(.dateTime)
        settings.enablesCalendar = groups.contains(.calendar)
        settings.enablesReminders = groups.contains(.reminders)
        settings.enablesNotifications = groups.contains(.notifications)
        settings.enablesPhotos = groups.contains(.photos)
        settings.enablesContacts = groups.contains(.contacts)
        settings.enablesTextResources = groups.contains(.resources)
        settings.enablesWebFetch = groups.contains(.webFetch)
        settings.enablesWebSearch = groups.contains(.webSearch)
        settings.enablesAskUser = groups.contains(.askUser)
        return settings
    }
    func requirements(settings: DemoLiveChatSettings, hasModelKey: Bool, hasSearchKey: Bool,
                      hasDeepSeekSearchKey: Bool = false, pendingTexts: Int = 0,
                      pendingImages: Int = 0, pendingFiles: Int = 0) -> [DemoLabRequirement] {
        var values: [DemoLabRequirement] = []
        if !hasModelKey || settings.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            values.append(.init(kind: .model, message: "先配置模型和 API Key，工具任务会交给这个模型执行。", actionTitle: "配置模型"))
        }
        if groups.contains(.webFetch), (try? BoneWebHostPolicy(allowedHosts: settings.webHostNames)) == nil {
            values.append(.init(kind: .webHosts, message: "网页读取已勾选，需要先设置允许访问的域名。", actionTitle: "配置网页域名"))
        }
        if groups.contains(.webSearch) {
            if !settings.search.automaticEnabled {
                values.append(.init(kind: .searchKey, message: "模型自动搜索需要先启用百度网页问答、Brave 或 DeepSeek 通道并选择自动搜索方式。", actionTitle: "配置搜索"))
            } else if settings.search.automaticChannel.requiresAPIKey &&
                        !(settings.search.automaticChannel == .deepSeek ? hasDeepSeekSearchKey : hasSearchKey) {
                values.append(.init(kind: .searchKey, message: "\(settings.search.automaticChannel.title) 还没有搜索 Key。", actionTitle: "配置搜索 Key"))
            }
        }
        if pendingTexts > 0 && !groups.contains(.resources) {
            values.append(.init(kind: .resources, message: "待发送的文本材料需要开启资料工具。", actionTitle: "勾选资料工具"))
        }
        if pendingFiles > 0 && !groups.contains(.resources) {
            values.append(.init(kind: .resources, message: "待发送的文件需要开启文件资源工具。", actionTitle: "勾选资料工具"))
        }
        if pendingImages > 0 && (settings.visionPolicy == .disabled || (try? settings.visionPolicy.validate(settings: settings)) == nil) {
            values.append(.init(kind: .vision, message: "待发送的图片需要与当前模型匹配的图片输入规则。", actionTitle: "配置图片理解"))
        }
        return values
    }
}

struct DemoLabRequirement: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case model, webHosts, searchKey, resources, vision }
    let kind: Kind
    let message: String
    let actionTitle: String
    var id: String { kind.rawValue }
}

struct DemoToolUsage: Identifiable, Sendable {
    let group: BoneBuiltInToolGroup
    let symbol: String
    let purpose: String
    let preparation: String
    let example: String
    let steps: [String]
    var id: String { group.id }
    var title: String { group.title }

    static func guide(for group: BoneBuiltInToolGroup) -> Self {
        switch group {
        case .calculator:
            return .init(group: group, symbol: "function", purpose: "让模型准确计算表达式和常用数学函数。",
                preparation: "勾选后即可使用，无需额外账号。", example: "请调用计算器工具计算 128 × 36，再用一句话解释结果。",
                steps: ["把计算要求写进任务，点击运行。", "模型决定何时调用计算器，App 在本机计算。", "结果回传模型，最终回复显示在对话页。"])
        case .dateTime:
            return .init(group: group, symbol: "clock", purpose: "查询设备时间、转换时区、计算日期与时间差。",
                preparation: "当前时间由设备提供；可在任务中明确时区。", example: "请使用日期时间工具查询现在的时间，并转换为 Asia/Shanghai 时区。",
                steps: ["在任务中描述日期、时区或时间差。", "模型将需求转换为日期工具参数。", "工具返回实际时间，模型整理为回复。"])
        case .calendar:
            return .init(group: group, symbol: "calendar", purpose: "查询和管理授权的日历事件。",
                preparation: "首次使用时系统会请求日历权限；创建、修改和删除会再次确认。", example: "请查找明天上午的日历安排，并把下午三点的会议改到四点。",
                steps: ["先查询目标日期的事件。", "修改或删除前核对事件和时间。", "确认后由 App 写入系统日历。"])
        case .reminders:
            return .init(group: group, symbol: "checklist", purpose: "查询、创建和完成提醒事项。",
                preparation: "首次使用时系统会请求提醒事项权限；创建、完成和删除会再次确认。", example: "请查找今天未完成的提醒，并创建一条明天上午九点提醒我提交报告。",
                steps: ["模型先读取有限范围的提醒事项。", "写入前展示标题、时间和列表。", "确认后由 App 写入提醒事项。"])
        case .notifications:
            return .init(group: group, symbol: "bell", purpose: "创建和管理本 App 自己安排的本地通知。",
                preparation: "首次安排通知时系统会请求通知权限；取消和安排会再次确认。", example: "请在明天上午九点安排一条通知，提醒我提交报告。",
                steps: ["模型生成通知时间和内容。", "App 展示一次性确认。", "通知只由本 App 创建和管理。"])
        case .photos:
            return .init(group: group, symbol: "photo", purpose: "把用户已选择或 App 已生成的图片保存到相册。",
                preparation: "选择图片使用系统 PhotosPicker；保存图片时请求添加权限并需要确认。", example: "请把当前对话中生成的图片保存到相册。",
                steps: ["用户从相册选择图片或先生成图片。", "模型只能引用已登记的图片 ID。", "确认后 App 保存到系统相册。"])
        case .contacts:
            return .init(group: group, symbol: "person.crop.circle", purpose: "查询和管理授权的联系人。",
                preparation: "首次使用时系统会请求联系人权限；创建、修改和删除会再次确认。", example: "请查找联系人张三的电话，并在确认后把他的公司更新为新公司。",
                steps: ["模型按姓名、电话或邮箱查找有限结果。", "写入前展示联系人标识和变更字段。", "确认后由 App 写入系统通讯录。"])
        case .resources:
            return .init(group: group, symbol: "doc.text.magnifyingglass", purpose: "在已导入文本中列出、检索并分页读取原文。",
                preparation: "先导入 UTF-8 文本，或从文本分页专项加入材料。", example: "请使用资料工具列出已导入材料，检索关键内容并说明依据。",
                steps: ["添加文本材料；运行前材料只保留在本机。", "运行后模型先收到预览，可按需检索和分页读取。", "回复可引用原文，工具不会访问未导入的文件。"])
        case .webFetch:
            return .init(group: group, symbol: "globe", purpose: "读取指定网页的静态正文并交给模型整理。",
                preparation: "先配置精确的允许域名；网页需支持静态 HTML 或文本。", example: "请使用网页读取工具阅读 https://example.com ，简要说明页面内容并附来源。",
                steps: ["把完整 HTTPS 网页地址写进任务。", "首次联网时确认本次任务的网站和搜索范围。", "同一任务内后续读取不再逐次确认；拒绝会结束本次请求。"])
        case .webSearch:
            return .init(group: group, symbol: "magnifyingglass", purpose: "让模型读取百度公开搜索结果或通过搜索 API 查找信息，也可手动浏览网页选取。",
                preparation: "百度网页问答无需搜索 Key；Brave、DeepSeek API 需各自的 Key；百度、必应网页可手动浏览。", example: "请使用联网搜索工具查询今天桐乡温度，并给出来源链接。",
                steps: ["在搜索设置中启用通道；勾选联网搜索后再运行任务。", "每个任务首次联网确认一次；百度网页问答在后台读取公开结果，遇验证即停止，模型用量仍按模型账户计。", "百度网页问答和 API 均返回结构化结果供模型整理；手动网页搜索由你浏览选取后加入任务。"])
        case .askUser:
            return .init(group: group, symbol: "questionmark.bubble", purpose: "让模型通过单选、多选或文本澄清你的需求。",
                preparation: "保持 App 可操作；等待回答时不会自动替你选择。", example: "请先通过询问用户工具确认我偏好的回答风格，再介绍这个 Agent 能做什么。",
                steps: ["在任务中说明需要先确认的问题。", "模型调用后显示问答面板，选择或输入真实回答。", "提交后模型继续；取消或超时会结束本次请求。"])
        }
    }
}
