import Foundation

/// Selection metadata only. Presets never register tools, create clients, grant access, or perform I/O.
public enum BoneBuiltInToolGroup: String, Codable, CaseIterable, Identifiable, Sendable {
    case calculator, dateTime, resources, webFetch, webSearch, askUser
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .calculator: return "计算器"
        case .dateTime: return "日期与时间"
        case .resources: return "授权资料检索与读取"
        case .webFetch: return "网页正文读取"
        case .webSearch: return "联网搜索"
        case .askUser: return "询问用户"
        }
    }
    public var toolIDs: [String] {
        switch self {
        case .calculator: return ["math.calculate"]
        case .dateTime: return ["time.query"]
        case .resources: return ["resource.list", "resource.search", "resource.readText",
                                 "resource.inspect", "resource.detectFormat", "resource.readWindow", "resource.readOffice",
                                 "resource.listEntries", "resource.readBytes", "resource.readPDFLayout", "resource.ocr"]
        case .webFetch: return ["web.fetch"]
        case .webSearch: return ["web.search"]
        case .askUser: return ["user.ask"]
        }
    }
    public var requiresNetwork: Bool { self == .webFetch || self == .webSearch }
    public var requiresHostInteraction: Bool { self == .askUser }
}

public enum BoneBuiltInToolPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case basic, resources, research
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .basic: return "基础助手"
        case .resources: return "资料助手"
        case .research: return "研究助手"
        }
    }
    public var groups: [BoneBuiltInToolGroup] {
        let basic: [BoneBuiltInToolGroup] = [.calculator, .dateTime, .askUser]
        switch self {
        case .basic: return basic
        case .resources: return basic + [.resources]
        case .research: return basic + [.resources, .webFetch, .webSearch]
        }
    }
}
