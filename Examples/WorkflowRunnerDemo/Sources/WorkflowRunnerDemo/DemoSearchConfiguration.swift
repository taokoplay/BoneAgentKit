import Foundation

/// Host search preferences. Credentials never belong in this value.
struct DemoSearchConfiguration: Codable, Equatable, Sendable {
    var isEnabled = true
    var browserEnabled = true
    var baiduWebEnabled = false
    var braveEnabled = false
    var deepSeekEnabled = false
    var preferredChannel: DemoSearchChannel = .browser
    var automaticChannel: DemoSearchChannel = .brave
    var browserEngine: DemoBrowserSearchEngine = .bing
    var keepsBrowserSession = false

    init() {}

    func selectingBaiduWebForTask() -> Self {
        var selected = self
        selected.isEnabled = true
        selected.baiduWebEnabled = true
        selected.automaticChannel = .baiduWeb
        return selected
    }

    /// A user-selected search tool can use public Baidu when no automatic service was configured.
    /// Existing enabled API channels retain their explicit choice and credential requirements.
    func preparedForAutomaticToolSelection() -> Self {
        guard !baiduWebEnabled && !braveEnabled && !deepSeekEnabled else { return self }
        return selectingBaiduWebForTask()
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, browserEnabled, baiduWebEnabled, braveEnabled, deepSeekEnabled
        case preferredChannel, automaticChannel, browserEngine, keepsBrowserSession
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        browserEnabled = try values.decodeIfPresent(Bool.self, forKey: .browserEnabled) ?? browserEnabled
        baiduWebEnabled = try values.decodeIfPresent(Bool.self, forKey: .baiduWebEnabled) ?? baiduWebEnabled
        braveEnabled = try values.decodeIfPresent(Bool.self, forKey: .braveEnabled) ?? braveEnabled
        deepSeekEnabled = try values.decodeIfPresent(Bool.self, forKey: .deepSeekEnabled) ?? deepSeekEnabled
        preferredChannel = try values.decodeIfPresent(DemoSearchChannel.self, forKey: .preferredChannel) ?? preferredChannel
        automaticChannel = try values.decodeIfPresent(DemoSearchChannel.self, forKey: .automaticChannel) ?? automaticChannel
        browserEngine = try values.decodeIfPresent(DemoBrowserSearchEngine.self, forKey: .browserEngine) ?? browserEngine
        keepsBrowserSession = try values.decodeIfPresent(Bool.self, forKey: .keepsBrowserSession) ?? keepsBrowserSession
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(isEnabled, forKey: .isEnabled)
        try values.encode(browserEnabled, forKey: .browserEnabled)
        // Preserve the encoded legacy route used by existing conversation bindings.
        if baiduWebEnabled { try values.encode(true, forKey: .baiduWebEnabled) }
        try values.encode(braveEnabled, forKey: .braveEnabled)
        try values.encode(deepSeekEnabled, forKey: .deepSeekEnabled)
        try values.encode(preferredChannel, forKey: .preferredChannel)
        try values.encode(automaticChannel, forKey: .automaticChannel)
        try values.encode(browserEngine, forKey: .browserEngine)
        try values.encode(keepsBrowserSession, forKey: .keepsBrowserSession)
    }

    func channels() -> [DemoSearchChannel] {
        guard isEnabled else { return [] }
        return DemoSearchChannel.allCases.filter { channel in
            switch channel {
            case .browser: browserEnabled
            case .baiduWeb: baiduWebEnabled
            case .brave: braveEnabled
            case .deepSeek: deepSeekEnabled
            }
        }
    }

    func checkedForSave() throws -> Self {
        guard !isEnabled || channels().contains(preferredChannel) else { throw DemoSearchError.noDefaultChannel }
        if isEnabled && (baiduWebEnabled || braveEnabled || deepSeekEnabled) {
            guard automaticChannel.supportsAutomaticSearch, channels().contains(automaticChannel) else {
                throw DemoSearchError.noDefaultChannel
            }
        }
        return self
    }
    var automaticEnabled: Bool { isEnabled && automaticChannel.supportsAutomaticSearch && channels().contains(automaticChannel) }
}

enum DemoSearchChannel: String, Codable, CaseIterable, Identifiable, Sendable {
    case browser, baiduWeb, brave, deepSeek
    var id: String { rawValue }
    var title: String {
        switch self {
        case .browser: "网页搜索"
        case .baiduWeb: "百度网页问答"
        case .brave: "Brave Search"
        case .deepSeek: "DeepSeek Search"
        }
    }
    var mode: String {
        switch self {
        case .browser: "百度 / 必应网页搜索 · 手动浏览选取 · 无需搜索 Key"
        case .baiduWeb: "任务内授权后读取公开结果，无搜索 API Key"
        case .brave, .deepSeek: "API 搜索 · 可供模型调用"
        }
    }
    var symbol: String {
        switch self {
        case .browser: "globe"
        case .baiduWeb: "globe.badge.magnifyingglass"
        case .brave: "magnifyingglass"
        case .deepSeek: "sparkle.magnifyingglass"
        }
    }
    var supportsAutomaticSearch: Bool { self != .browser }
    var requiresAPIKey: Bool { self == .brave || self == .deepSeek }
    func initialURL(query: String, engine: DemoBrowserSearchEngine) throws -> URL {
        guard self == .browser else { throw DemoSearchError.browserUnavailable }
        return try engine.url(query: query)
    }
}

enum DemoBrowserSearchEngine: String, Codable, CaseIterable, Identifiable, Sendable {
    case bing, baidu
    var id: String { rawValue }
    var title: String { self == .bing ? "必应" : "百度" }
    func url(query: String) throws -> URL {
        let query = try DemoSearchQuery(query).text
        var components = URLComponents()
        components.scheme = "https"
        components.host = self == .bing ? "www.bing.com" : "www.baidu.com"
        components.path = self == .bing ? "/search" : "/s"
        components.queryItems = [.init(name: self == .bing ? "q" : "wd", value: query)]
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw DemoSearchError.invalidQuery }
        return url
    }
}

struct DemoSearchQuery: Sendable {
    static let maximumBytes = 2_048
    let text: String
    init(_ text: String) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.count <= Self.maximumBytes,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw DemoSearchError.invalidQuery }
        self.text = text
    }
}

enum DemoSearchError: Error, Equatable, Sendable {
    case invalidQuery, noDefaultChannel, disabled, missingKey, browserUnavailable, invalidSelection, pageChanged, unsupportedPage
    case manualSearchRequired
    var message: String {
        switch self {
        case .invalidQuery: "请填写简短的搜索词；DeepSeek 最多 128 个字符，其他方式最多 2 KiB。"
        case .noDefaultChannel: "请启用默认方式和模型自动搜索通道，或关闭不使用的开关。"
        case .disabled: "搜索通道已关闭，请先在搜索设置中启用。"
        case .missingKey: "当前搜索通道需要 API Key，请到搜索设置填写。"
        case .browserUnavailable: "请在搜索页运行这个通道；手动网页搜索可打开浏览页面。"
        case .manualSearchRequired: "这是搜索结果页，静态正文读取不能代替关键词搜索。可选择「百度搜索并回答」，或手动浏览选取结果；百度网页搜索无需搜索 API Key。"
        case .invalidSelection: "请选择一小段内容，并保留有效的 HTTPS 来源链接。"
        case .pageChanged: "页面已经变化，请重新选取文字。"
        case .unsupportedPage: "DeepSeek 搜索不支持分页，请重新搜索或切换 Brave Search。"
        }
    }
}
