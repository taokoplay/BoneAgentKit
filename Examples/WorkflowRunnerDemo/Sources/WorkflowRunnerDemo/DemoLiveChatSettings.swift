import Foundation
import BoneAgentKit
import CryptoKit
import BoneAgentTools

/// Catalog identifiers are persisted as a single string. The old DeepSeek token
/// retains its original OpenAI connection until the user explicitly selects anew.
struct DemoChatProvider: RawRepresentable, Codable, Hashable, CaseIterable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    static let deepSeek = Self(rawValue: "DeepSeek")
    static let openAI = Self(rawValue: "OpenAI")
    static let anthropic = Self(rawValue: "Anthropic")
    static let gemini = Self(rawValue: "Google")
    static let customOpenAI = Self(rawValue: "OpenAICompatible")

    static var allCases: [Self] {
        guard let catalog = try? bundledCatalog() else { return [] }
        return catalog.providers.filter {
            $0.apiPaths["chat"] != nil
        }.map { Self(rawValue: $0.ident) }
    }

    var id: String { catalogIdent }
    var catalogIdent: String {
        switch rawValue {
        case "deepSeek": return "DeepSeek"
        case "openAI": return "OpenAI"
        case "anthropic": return "Anthropic"
        case "gemini": return "Google"
        case "customOpenAI": return "OpenAICompatible"
        default: return (try? Self.bundledCatalog().provider(ident: rawValue))?.ident ?? rawValue
        }
    }

    private var entry: BoneInferenceProviderCatalog.Entry? { try? catalogEntry() }
    var title: String { entry?.title ?? "未知服务商" }
    var iconID: String { entry?.iconID ?? "" }
    var defaultBaseURL: String { entry?.defaultBaseURL?.absoluteString ?? "" }
    var isCompatibleGateway: Bool {
        catalogIdent == "OpenAICompatible" || catalogIdent == "AnthropicCompatible"
    }
    var usesAccountModelList: Bool {
        isCompatibleGateway || catalogIdent == "Zhipu" || catalogIdent == "ZhipuCodingPlan"
    }
    var defaultModelID: String {
        guard !usesAccountModelList else { return "" }
        return entry?.models.first { !$0.deprecated && $0.capabilities.contains(.chat) }?.id ?? ""
    }
    var isLegacyOpenAIConnection: Bool { rawValue == "deepSeek" }
    // These inert display fallbacks never authorize a connection: configuration
    // creation first requires a known catalog entry.
    var kind: BoneInferenceProviderKind {
        isLegacyOpenAIConnection ? .custom : (entry?.providerKind ?? .custom)
    }
    var authenticationMode: BoneInferenceAuthenticationMode {
        isLegacyOpenAIConnection ? .bearer : (entry?.authenticationMode ?? .bearer)
    }
    var supportsFullEndpointURL: Bool {
        if isLegacyOpenAIConnection || isCompatibleGateway { return true }
        guard let entry else { return false }
        switch entry.providerProtocol {
        case .openAI, .customOpenAI, .newAPI, .google: return true
        case .anthropic: return false
        }
    }

    init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isLegacyOpenAIConnection ? rawValue : catalogIdent)
    }

    static func bundledCatalog() throws -> BoneInferenceProviderCatalog {
        try DemoBundledChatCatalog.value.get()
    }

    func catalogEntry() throws -> BoneInferenceProviderCatalog.Entry {
        try catalogEntry(in: Self.bundledCatalog())
    }

    func catalogEntry(in catalog: BoneInferenceProviderCatalog) throws -> BoneInferenceProviderCatalog.Entry {
        // An empty chat path defers to the engine for compatible connections;
        // absence of the operation identifies a channel that cannot serve chat.
        guard let entry = catalog.provider(ident: catalogIdent), entry.apiPaths["chat"] != nil else {
            throw DemoChatConfigurationError.unknownProvider
        }
        return entry
    }
}

private enum DemoBundledChatCatalog {
    /// Swift initializes immutable static values once, including failed loads.
    static let value: Result<BoneInferenceProviderCatalog, DemoChatConfigurationError> = {
        do { return .success(try .bundled()) }
        catch { return .failure(.catalogUnavailable) }
    }()
}

enum DemoChatConfigurationError: Error, Equatable, Sendable {
    case invalidURL, missingModel, missingKey, invalidKey, invalidOutputLimit, systemPromptTooLarge
    case catalogUnavailable, unknownProvider, unsupportedFullEndpointURL, fullEndpointDiscovery
    case invalidContextWindow, invalidVisionConfiguration, invalidToolConfiguration
    var message: String {
        switch self {
        case .invalidURL: return "请填写有效的 HTTPS 接口地址，不包含账号、密码、查询参数或片段。"
        case .missingModel: return "请填写服务商提供的模型 ID。"
        case .missingKey: return "请先在模型设置中填写 API Key。"
        case .invalidKey: return "API Key 含有换行或不支持的字符，请重新粘贴。"
        case .invalidOutputLimit: return "回复上限应在 App 可配置范围（128～1000000 Token）内，且不能超过当前模型的已知输出上限。"
        case .systemPromptTooLarge: return "系统指令过长，请缩短到 16 KiB 以内。"
        case .catalogUnavailable: return "内置服务商目录暂不可用，请重新打开应用后重试。"
        case .unknownProvider: return "当前服务商不在聊天目录中，请重新选择服务商。"
        case .unsupportedFullEndpointURL: return "当前服务商不支持完整接口地址，请填写服务基址。"
        case .fullEndpointDiscovery: return "完整聊天接口地址无法发现模型，请切换为服务基址后刷新模型。"
        case .invalidContextWindow: return "上下文窗口或摘要预算无效。窗口应为 4096～2000000 Token，并能在模型容量内预留输出、协议和安全余量。"
        case .invalidVisionConfiguration: return "图片规则尚未绑定当前连接与模型，或估算参数无效。请在图片设置中重新配置。"
        case .invalidToolConfiguration: return "请检查工具配置：网页读取需要允许的公开域名；联网搜索需要独立的搜索 Key。"
        }
    }
}

/// Ordinary preferences deliberately contain no API key or conversation text.
struct DemoLiveChatSettings: Codable, Equatable, Sendable {
    var provider: DemoChatProvider = .deepSeek
    var baseURL = DemoChatProvider.deepSeek.defaultBaseURL
    var modelID = DemoChatProvider.deepSeek.defaultModelID
    var usesFullEndpointURL = false
    /// 业务角色预设；默认自定义以保持旧版本行为。
    var promptPreset: DemoPromptPreset = .custom
    var systemPrompt = "你是一个简洁、可靠的中文助手。工具可用时，根据问题决定是否调用，并根据真实工具结果回答。"
    var enablesCalculator = false
    var maximumOutputTokens = 1024
    var usesStreaming = true
    var managesContext = true
    var summarizesContext = false
    var contextWindowTokens = 32_768
    // Optional fields preserve old settings and conversation fingerprints when unset.
    var contextToolHistoryCompaction: Bool?
    var contextSummaryOutputTokens: Int?
    var preservesConversation = false
    var enablesTextResources = false
    var visionPolicy: DemoVisionPolicy = .disabled
    var visionTokenBase = 0
    var visionTokensPerMegapixel = 0
    var visionBindingID = ""
    var enablesDateTime = false
    var enablesCalendar = false
    var enablesReminders = false
    var enablesNotifications = false
    var enablesPhotos = false
    var enablesContacts = false
    var enablesLocation = false
    var enablesShare = false
    var enablesCompose = false
    var enablesAskUser = false

    /// 当前设置是否启用了任一 Apple 系统能力。
    var enablesAppleTools: Bool { enablesCalendar || enablesReminders || enablesNotifications || enablesPhotos || enablesContacts || enablesLocation || enablesShare || enablesCompose }
    var enablesWebFetch = false
    var enablesWebSearch = false
    var webAllowedHosts = ""
    var searchConfiguration: DemoSearchConfiguration?

    var search: DemoSearchConfiguration {
        get {
            if let searchConfiguration { return searchConfiguration }
            var legacy = DemoSearchConfiguration()
            legacy.braveEnabled = enablesWebSearch
            return legacy
        }
        set { searchConfiguration = newValue }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case provider, baseURL, modelID, usesFullEndpointURL, promptPreset, systemPrompt, enablesCalculator, maximumOutputTokens
        case usesStreaming, managesContext, summarizesContext, contextWindowTokens, preservesConversation, enablesTextResources
        case contextToolHistoryCompaction, contextSummaryOutputTokens
        case visionPolicy, visionTokenBase, visionTokensPerMegapixel, visionBindingID
        case enablesDateTime, enablesCalendar, enablesReminders, enablesNotifications, enablesPhotos, enablesContacts, enablesLocation, enablesShare, enablesCompose
        case enablesAskUser, enablesWebFetch, enablesWebSearch, webAllowedHosts
        case searchConfiguration
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = try c.decodeIfPresent(DemoChatProvider.self, forKey: .provider) ?? provider
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? provider.defaultBaseURL
        modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? provider.defaultModelID
        usesFullEndpointURL = try c.decodeIfPresent(Bool.self, forKey: .usesFullEndpointURL) ?? false
        promptPreset = try c.decodeIfPresent(DemoPromptPreset.self, forKey: .promptPreset) ?? .custom
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? systemPrompt
        enablesCalculator = try c.decodeIfPresent(Bool.self, forKey: .enablesCalculator) ?? false
        maximumOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maximumOutputTokens) ?? maximumOutputTokens
        usesStreaming = try c.decodeIfPresent(Bool.self, forKey: .usesStreaming) ?? usesStreaming
        managesContext = try c.decodeIfPresent(Bool.self, forKey: .managesContext) ?? managesContext
        summarizesContext = try c.decodeIfPresent(Bool.self, forKey: .summarizesContext) ?? false
        contextWindowTokens = try c.decodeIfPresent(Int.self, forKey: .contextWindowTokens) ?? contextWindowTokens
        contextToolHistoryCompaction = try c.decodeIfPresent(Bool.self, forKey: .contextToolHistoryCompaction)
        contextSummaryOutputTokens = try c.decodeIfPresent(Int.self, forKey: .contextSummaryOutputTokens)
        preservesConversation = try c.decodeIfPresent(Bool.self, forKey: .preservesConversation) ?? false
        enablesTextResources = try c.decodeIfPresent(Bool.self, forKey: .enablesTextResources) ?? false
        visionPolicy = try c.decodeIfPresent(DemoVisionPolicy.self, forKey: .visionPolicy) ?? .disabled
        visionTokenBase = try c.decodeIfPresent(Int.self, forKey: .visionTokenBase) ?? 0
        visionTokensPerMegapixel = try c.decodeIfPresent(Int.self, forKey: .visionTokensPerMegapixel) ?? 0
        visionBindingID = try c.decodeIfPresent(String.self, forKey: .visionBindingID) ?? ""
        enablesDateTime = try c.decodeIfPresent(Bool.self, forKey: .enablesDateTime) ?? false
        enablesCalendar = try c.decodeIfPresent(Bool.self, forKey: .enablesCalendar) ?? false
        enablesReminders = try c.decodeIfPresent(Bool.self, forKey: .enablesReminders) ?? false
        enablesNotifications = try c.decodeIfPresent(Bool.self, forKey: .enablesNotifications) ?? false
        enablesPhotos = try c.decodeIfPresent(Bool.self, forKey: .enablesPhotos) ?? false
        enablesContacts = try c.decodeIfPresent(Bool.self, forKey: .enablesContacts) ?? false
        enablesLocation = try c.decodeIfPresent(Bool.self, forKey: .enablesLocation) ?? false
        enablesShare = try c.decodeIfPresent(Bool.self, forKey: .enablesShare) ?? false
        enablesCompose = try c.decodeIfPresent(Bool.self, forKey: .enablesCompose) ?? false
        enablesAskUser = try c.decodeIfPresent(Bool.self, forKey: .enablesAskUser) ?? false
        enablesWebFetch = try c.decodeIfPresent(Bool.self, forKey: .enablesWebFetch) ?? false
        enablesWebSearch = try c.decodeIfPresent(Bool.self, forKey: .enablesWebSearch) ?? false
        webAllowedHosts = try c.decodeIfPresent(String.self, forKey: .webAllowedHosts) ?? ""
        searchConfiguration = try c.decodeIfPresent(DemoSearchConfiguration.self, forKey: .searchConfiguration)
    }

    /// 当前设置对应的 SDK 业务提示词 Profile。
    /// - Returns: 自定义模式返回 nil，其余模式返回固定版本的可信 Profile。
    var promptProfile: BonePromptProfile? { promptPreset.promptProfile() }

    var visionBindingFingerprint: String {
        let parts = [provider.kind.rawValue, usesFullEndpointURL ? "endpoint" : "base",
                     Self.connectionURL(baseURL)?.absoluteString ?? baseURL,
                     modelID.trimmingCharacters(in: .whitespacesAndNewlines)]
        let data = (try? JSONEncoder().encode(parts)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    var conversationBindingID: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Browser preferences preserve the old binding; each automatic result source binds its own history.
        var bound = self
        if enablesWebSearch && search.automaticChannel == .deepSeek {
            var route = DemoSearchConfiguration()
            route.deepSeekEnabled = true
            route.automaticChannel = .deepSeek
            bound.searchConfiguration = route
        } else if enablesWebSearch && search.automaticChannel == .baiduWeb {
            var route = DemoSearchConfiguration()
            route.baiduWebEnabled = true
            route.automaticChannel = .baiduWeb
            bound.searchConfiguration = route
        } else { bound.searchConfiguration = nil }
        let data = (try? encoder.encode(bound)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    mutating func bindVisionToCurrentModel() {
        visionBindingID = visionPolicy == .disabled ? "" : visionBindingFingerprint
    }

    mutating func resetVisionBinding() {
        visionPolicy = .disabled
        visionBindingID = ""
    }

    mutating func selectProvider(_ provider: DemoChatProvider) {
        self.provider = provider
        baseURL = provider.defaultBaseURL
        modelID = provider.defaultModelID
        usesFullEndpointURL = false
        resetVisionBinding()
    }

    var webHostNames: [String] {
        Array(Set(webAllowedHosts.components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { $0.lowercased() }.filter { !$0.isEmpty })).sorted()
    }

    mutating func applyToolPreset(_ preset: BoneBuiltInToolPreset, hasSearchKey: Bool) {
        enablesCalculator = true
        enablesDateTime = true
        enablesAskUser = true
        enablesTextResources = preset != .basic
        enablesWebFetch = preset == .research && !webHostNames.isEmpty
        enablesWebSearch = preset == .research && hasSearchKey
    }

    func validated() throws -> Self {
        var copy = self
        let (_, url) = try connectionValues()
        copy.baseURL = url.absoluteString
        copy.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.modelID.isEmpty, copy.modelID.utf8.count <= 256,
              !copy.modelID.contains(where: { $0.isNewline }) else { throw DemoChatConfigurationError.missingModel }
        let capacity = copy.modelCapacity
        guard maximumOutputTokens >= 128, maximumOutputTokens <= capacity.selectableOutputMaximum else {
            throw DemoChatConfigurationError.invalidOutputLimit
        }
        guard !enablesWebSearch || search.automaticEnabled else { throw DemoChatConfigurationError.invalidToolConfiguration }
        guard systemPrompt.utf8.count <= 16_384 else { throw DemoChatConfigurationError.systemPromptTooLarge }
        guard (4_096...2_000_000).contains(contextWindowTokens) else { throw DemoChatConfigurationError.invalidContextWindow }
        if managesContext {
            guard maximumOutputTokens < copy.effectiveContextWindowTokens, copy.availableInputTokens != nil else {
                throw DemoChatConfigurationError.invalidContextWindow
            }
            if summarizesContext {
                guard summaryOutputTokens >= 128, summaryOutputTokens <= capacity.selectableOutputMaximum,
                      summaryOutputTokens < copy.effectiveContextWindowTokens,
                      (try? capacity.contextBudget(hostTokens: contextWindowTokens).availableInputTokens(
                        configuredOutputTokens: summaryOutputTokens, preferredOutputTokens: summaryOutputTokens,
                        protocolReserveTokens: 128, safetyMarginTokens: copy.contextSafetyMarginTokens)) != nil else {
                    throw DemoChatConfigurationError.invalidContextWindow
                }
            }
        }
        guard webAllowedHosts.utf8.count <= 2_048, webHostNames.count <= 32,
              !enablesWebFetch || !webHostNames.isEmpty,
              webHostNames.allSatisfy({ host in
                  host.utf8.count <= 253 && host.contains(".") &&
                  host.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 } &&
                  !host.hasPrefix(".") && !host.hasSuffix(".") &&
                  !host.hasSuffix(".localhost") && !host.hasSuffix(".local") &&
                  host.split(separator: ".").last?.contains(where: { $0.isLetter }) == true
              }) else { throw DemoChatConfigurationError.invalidToolConfiguration }
        copy.webAllowedHosts = webHostNames.joined(separator: "\n")
        if visionPolicy != .disabled {
            guard visionBindingID == visionBindingFingerprint else { throw DemoChatConfigurationError.invalidVisionConfiguration }
            if visionPolicy == .openAI41Mini {
                guard provider.kind == .openAI,
                      ["gpt-4.1-mini", "gpt-4.1-mini-2025-04-14"].contains(copy.modelID) else {
                    throw DemoChatConfigurationError.invalidVisionConfiguration
                }
            } else {
                guard (1...100_000).contains(visionTokenBase),
                      (1...100_000).contains(visionTokensPerMegapixel) else {
                    throw DemoChatConfigurationError.invalidVisionConfiguration
                }
            }
        }
        return copy
    }

    func providerConfiguration(apiKey: String) throws -> BoneInferenceProviderConfiguration {
        try validated().makeConfiguration(apiKey: apiKey)
    }

    /// Model discovery needs a connection, not a selected model or generation options.
    func discoveryConfiguration(apiKey: String) throws -> BoneInferenceProviderConfiguration {
        _ = try provider.catalogEntry()
        guard !usesFullEndpointURL || provider.isCompatibleGateway else {
            throw DemoChatConfigurationError.fullEndpointDiscovery
        }
        return try makeConfiguration(apiKey: apiKey, allowsAnonymous: provider.isCompatibleGateway)
    }

    /// Shared with offline catalog projection; invalid overrides may use catalog defaults there.
    static func connectionURL(_ value: String) -> URL? {
        let address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, let url = components.url, url.host != nil else { return nil }
        return url
    }

    private func connectionValues() throws -> (BoneInferenceProviderCatalog.Entry, URL) {
        let entry = try provider.catalogEntry()
        guard !usesFullEndpointURL || provider.supportsFullEndpointURL else {
            throw DemoChatConfigurationError.unsupportedFullEndpointURL
        }
        guard let url = Self.connectionURL(baseURL) else { throw DemoChatConfigurationError.invalidURL }
        return (entry, url)
    }

    private func makeConfiguration(apiKey: String, allowsAnonymous: Bool = false) throws -> BoneInferenceProviderConfiguration {
        let (entry, url) = try connectionValues()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard allowsAnonymous || !key.isEmpty else { throw DemoChatConfigurationError.missingKey }
        guard key.utf8.count <= 16_384, key.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DemoChatConfigurationError.invalidKey
        }
        let authenticationMode: BoneInferenceAuthenticationMode = provider.isLegacyOpenAIConnection
            ? .bearer : entry.authenticationMode
        // Empty paths defer to the engine's default chat endpoint.
        // Legacy DeepSeek must keep that same OpenAI default rather than new Anthropic paths.
        let paths = provider.isLegacyOpenAIConnection ? [:] : entry.apiPaths.filter { !$0.value.isEmpty }
        return .init(
            kind: provider.isLegacyOpenAIConnection ? .custom : entry.providerKind,
            apiKey: key,
            baseURL: url,
            authenticationMode: authenticationMode,
            usesFullEndpointURL: usesFullEndpointURL,
            userAgent: authenticationMode == .bearerWithUserAgent ? "BoneAgentLab/1.0" : nil,
            endpointOverrides: paths
        )
    }

    /// Keys are scoped to protocol and endpoint, not copied to a newly selected server.
    var credentialAccount: String {
        var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        let address = components?.string ?? baseURL
        return "\(provider.kind.rawValue)|\(usesFullEndpointURL ? "endpoint" : "base")|\(address)"
    }
}


/// Demo 可选的业务角色提示词预设；`.custom` 保持旧版自由文本行为。
enum DemoPromptPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case custom
    case personalAssistant = "personal-assistant"
    case softwareDeveloper = "software-developer"

    var id: String { rawValue }

    /// 预设在设置页面显示的名称。
    var title: String {
        switch self {
        case .custom: return "自定义助手"
        case .personalAssistant: return "个人 AI 助理"
        case .softwareDeveloper: return "软件开发助手"
        }
    }

    /// 预设在设置页面显示的用途说明。
    var summary: String {
        switch self {
        case .custom: return "仅使用下方的自定义助手说明。"
        case .personalAssistant: return "适合日常问答、计划整理和信息辅助。"
        case .softwareDeveloper: return "适合代码分析、实现建议和调试排查。"
        }
    }

    /// 将预设转换为 SDK 的纯值提示词 Profile。
    /// - Returns: 自定义模式返回 nil，固定角色返回可复用的 Profile。
    func promptProfile() -> BonePromptProfile? {
        switch self {
        case .custom:
            return nil
        case .personalAssistant:
            return BonePromptProfile(
                id: rawValue,
                version: 1,
                sections: [
                    .init(id: "identity", content: "你是个人 AI 助理。理解用户目标，优先给出可以直接执行的帮助。", order: 10),
                    .init(id: "behavior", content: "对不确定的信息明确说明限制。涉及外部事实时依据真实工具结果，不编造结果。", order: 20),
                    .init(id: "style", content: "使用简洁、清晰的中文回答。复杂任务先给结论，再列出必要步骤。", order: 30)
                ]
            )
        case .softwareDeveloper:
            return BonePromptProfile(
                id: rawValue,
                version: 1,
                sections: [
                    .init(id: "identity", content: "你是软件开发助手。帮助用户理解、设计、实现和验证软件。", order: 10),
                    .init(id: "engineering", content: "优先保持现有调用方兼容，先分析业务链路和失败边界，再给出可验证的实现。不要凭空假设未观察到的代码、接口或运行结果。", order: 20),
                    .init(id: "style", content: "回答使用清晰的技术中文。代码建议应说明原因、对用户的影响、性能和资源开销，并给出必要的验证方式。", order: 30)
                ]
            )
        }
    }
}
