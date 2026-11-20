import Foundation
import Observation
import BoneAgentTools

@Observable
@MainActor
final class LiveChatSettingsStore {
    private(set) var settings = DemoLiveChatSettings()
    private(set) var hasKey = false
    private(set) var hasSearchKey = false
    private(set) var hasDeepSeekSearchKey = false
    var hasAutomaticSearchKey: Bool {
        guard settings.search.automaticChannel.requiresAPIKey else { return true }
        return settings.search.automaticChannel == .deepSeek ? hasDeepSeekSearchKey : hasSearchKey
    }
    private(set) var configurationRevision: UInt64 = 0
    /// 当前聊天在每次设置提交前检查 session 私有附件；不持久化此回调。
    @ObservationIgnored var validateConversationPersistence: ((Bool) throws -> Void)?
    let isUITesting: Bool
    private let defaults: UserDefaults
    private let credentials: LiveChatCredentialStore
    private let preferenceKey = "live-chat.settings.v1"
    private let selectionKey = "lab.tool-selection.v1"
    private let searchAccount = "builtin-tools.brave-search.v1"
    private let deepSeekSearchAccount = "builtin-tools.deepseek-search.v1"

    init(isUITesting: Bool = false) {
        self.isUITesting = isUITesting
        let suite = "com.taokoplay.BoneAgentLab.ChatUITests"
        if isUITesting, let isolated = UserDefaults(suiteName: suite) {
            if !ProcessInfo.processInfo.arguments.contains("--preserve-ui-test-state") {
                isolated.removePersistentDomain(forName: suite)
            }
            defaults = isolated
        } else { defaults = .standard }
        credentials = LiveChatCredentialStore(service: isUITesting
            ? "com.taokoplay.BoneAgentLab.ChatUITests" : "com.taokoplay.BoneAgentLab.LiveChat")
        if let data = defaults.data(forKey: preferenceKey),
           let saved = try? JSONDecoder().decode(DemoLiveChatSettings.self, from: data),
           let valid = try? saved.validated() { settings = valid }
        #if DEBUG
        if isUITesting && ProcessInfo.processInfo.arguments.contains("--baidu-recovery-ui-test") {
            settings.selectProvider(.init(rawValue: "MiniMax"))
            settings.enablesCalculator = true; settings.enablesDateTime = true
            settings.enablesTextResources = true; settings.enablesAskUser = true
            settings.enablesWebFetch = true; settings.webAllowedHosts = "www.baidu.com"
            settings.enablesWebSearch = false; settings.search = .init()
        }
        #endif
        if isUITesting && !ProcessInfo.processInfo.arguments.contains("--preserve-ui-test-state") {
            try? credentials.remove(account: settings.credentialAccount)
            try? credentials.remove(account: searchAccount)
            try? credentials.remove(account: deepSeekSearchAccount)
        }
        refreshCredentialAvailability()
    }

    func key(for settings: DemoLiveChatSettings) throws -> String {
        try credentials.load(account: settings.credentialAccount) ?? ""
    }
    func searchKey() throws -> String { try credentials.load(account: searchAccount) ?? "" }
    func deepSeekSearchKey() throws -> String { try credentials.load(account: deepSeekSearchAccount) ?? "" }
    func automaticSearchKey(for proposed: DemoLiveChatSettings) throws -> String {
        guard proposed.search.automaticChannel.requiresAPIKey else { return "" }
        return proposed.search.automaticChannel == .deepSeek ? try deepSeekSearchKey() : try searchKey()
    }
    func refreshCredentialAvailability() {
        hasKey = (try? credentials.load(account: settings.credentialAccount))?.isEmpty == false
        hasSearchKey = (try? credentials.load(account: searchAccount))?.isEmpty == false
        hasDeepSeekSearchKey = (try? credentials.load(account: deepSeekSearchAccount))?.isEmpty == false
    }

    func stagedToolPlan() -> DemoLabToolPlan {
        guard let data = defaults.data(forKey: selectionKey),
              let plan = try? JSONDecoder().decode(DemoLabToolPlan.self, from: data) else {
            return .init(settings: settings)
        }
        return plan
    }
    func stageToolPlan(_ plan: DemoLabToolPlan) {
        if let data = try? JSONEncoder().encode(plan) { defaults.set(data, forKey: selectionKey) }
    }

    /// Applying a selection changes preferences only. The caller must reset an incompatible idle session before send.
    func applyToolPlan(_ plan: DemoLabToolPlan) throws {
        let proposed = plan.applying(to: settings)
        guard plan.requirements(settings: proposed, hasModelKey: true, hasSearchKey: hasSearchKey,
                                hasDeepSeekSearchKey: hasDeepSeekSearchKey).isEmpty else {
            throw DemoChatConfigurationError.invalidToolConfiguration
        }
        let valid = try proposed.validated()
        try persist(valid)
        stageToolPlan(plan)
    }

    func save(_ proposed: DemoLiveChatSettings, apiKey: String) throws {
        try validateConversationPersistence?(proposed.preservesConversation)
        let valid = try proposed.validated()
        let configuration = try valid.providerConfiguration(apiKey: apiKey)
        let encoded = try JSONEncoder().encode(valid)
        let previousKey = try credentials.load(account: valid.credentialAccount)
        let changed = valid != settings || previousKey != configuration.apiKey
        try credentials.save(configuration.apiKey, account: valid.credentialAccount)
        defaults.set(encoded, forKey: preferenceKey)
        settings = valid
        hasKey = true
        if changed { configurationRevision += 1 }
    }

    /// Shared instructions are preferences; editing them never reads or rewrites credentials.
    func saveAssistantInstructions(_ text: String) throws {
        var proposed = settings
        proposed.systemPrompt = text
        try persist(proposed.validated())
    }

    /// Explicit response-length choice. Does not read/write credentials or dispatch a request.
    func saveReplyLimit(_ tokens: Int) throws {
        var proposed = settings
        proposed.maximumOutputTokens = tokens
        try persist(proposed.validated())
    }

    /// Explicit user action; saves only the displayed output/window recommendation.
    func saveRecommendedModelCapacity() throws {
        var proposed = settings
        proposed.useRecommendedModelCapacity()
        try persist(proposed.validated())
    }

    /// A task action selects the public-page route without touching any credential or tool selection.
    func selectBaiduWebSearchForTask() throws {
        var proposed = settings
        proposed.search = proposed.search.selectingBaiduWebForTask()
        try persist(proposed.validated())
    }

    /// Called only after the user selects the search tool; never reads or writes credentials.
    @discardableResult
    func prepareSearchForToolSelection() throws -> Bool {
        let prepared = settings.search.preparedForAutomaticToolSelection()
        guard prepared != settings.search else { return false }
        var proposed = settings
        proposed.search = prepared
        try persist(proposed.validated())
        return true
    }

    /// Unified search preferences; API credentials remain in their existing Keychain account.
    func saveSearch(_ configuration: DemoSearchConfiguration, searchAPIKey: String,
                    deepSeekAPIKey: String, allowedHosts: String) throws {
        let configuration = try configuration.checkedForSave()
        let search = try validatedSearchKey(searchAPIKey)
        let deepSeek = try validatedSearchKey(deepSeekAPIKey)
        var proposed = settings
        proposed.search = configuration
        proposed.webAllowedHosts = allowedHosts
        if proposed.webHostNames.isEmpty { proposed.enablesWebFetch = false }
        let activeKey = configuration.automaticChannel == .deepSeek ? deepSeek : search
        if !configuration.automaticEnabled || (configuration.automaticChannel.requiresAPIKey && activeKey.isEmpty) {
            proposed.enablesWebSearch = false
        }
        let valid = try proposed.validated()
        if !valid.webHostNames.isEmpty { _ = try BoneWebHostPolicy(allowedHosts: valid.webHostNames) }
        let encoded = try JSONEncoder().encode(valid)
        let previous = try searchKey()
        let previousDeepSeek = try deepSeekSearchKey()
        try storeSearchKey(search)
        do {
            if deepSeek.isEmpty { try credentials.remove(account: deepSeekSearchAccount) }
            else { try credentials.save(deepSeek, account: deepSeekSearchAccount) }
        } catch {
            try? storeSearchKey(previous)
            throw error
        }
        let providerChanged = valid.search.automaticChannel != settings.search.automaticChannel
        let runtimeChanged = valid.conversationBindingID != settings.conversationBindingID || previous != search ||
            previousDeepSeek != deepSeek || (providerChanged && (valid.enablesWebSearch || settings.enablesWebSearch))
        defaults.set(encoded, forKey: preferenceKey)
        settings = valid
        hasSearchKey = !search.isEmpty
        hasDeepSeekSearchKey = !deepSeek.isEmpty
        if runtimeChanged { configurationRevision += 1 }
    }

    /// Network setup has its own save path and never reads or rewrites the model credential.
    func saveNetwork(allowedHosts: String, searchAPIKey: String) throws {
        let search = try validatedSearchKey(searchAPIKey)
        var proposed = settings
        proposed.webAllowedHosts = allowedHosts
        if proposed.webHostNames.isEmpty { proposed.enablesWebFetch = false }
        if search.isEmpty { proposed.enablesWebSearch = false }
        let valid = try proposed.validated()
        if !valid.webHostNames.isEmpty { _ = try BoneWebHostPolicy(allowedHosts: valid.webHostNames) }
        let encoded = try JSONEncoder().encode(valid)
        let previous = try searchKey()
        try storeSearchKey(search)
        let changed = valid != settings || previous != search
        defaults.set(encoded, forKey: preferenceKey)
        settings = valid
        hasSearchKey = !search.isEmpty
        if changed { configurationRevision += 1 }
    }

    func deleteKey(for proposed: DemoLiveChatSettings) throws {
        try credentials.remove(account: proposed.credentialAccount)
        refreshCredentialAvailability()
        configurationRevision += 1
    }
    private func persist(_ valid: DemoLiveChatSettings) throws {
        try validateConversationPersistence?(valid.preservesConversation)
        let data = try JSONEncoder().encode(valid)
        if valid != settings { configurationRevision += 1 }
        defaults.set(data, forKey: preferenceKey)
        settings = valid
    }
    private func validatedSearchKey(_ value: String) throws -> String {
        let search = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.utf8.count <= 4_096, search.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw DemoChatConfigurationError.invalidToolConfiguration
        }
        return search
    }
    private func storeSearchKey(_ value: String) throws {
        if value.isEmpty { try credentials.remove(account: searchAccount) }
        else { try credentials.save(value, account: searchAccount) }
    }
}
