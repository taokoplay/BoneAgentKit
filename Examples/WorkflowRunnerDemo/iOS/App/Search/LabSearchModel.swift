import Foundation
import Observation
import BoneAgentTools

@Observable @MainActor
final class LabSearchModel {
    struct PendingSelection: Identifiable { let id = UUID(); let value: DemoSearchSelection }
    var query = ""
    var channel: DemoSearchChannel
    var browserEngine: DemoBrowserSearchEngine
    var selection: PendingSelection?
    private(set) var isWorking = false
    private(set) var stopRequested = false
    private(set) var results: BoneWebSearchOutput?
    private(set) var resultQuery = ""
    private(set) var resultChannel: DemoSearchChannel?
    private(set) var browser: LabSearchBrowserModel?
    private(set) var message: String?
    private(set) var requestCount = 0
    @ObservationIgnored private let store: LiveChatSettingsStore
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    init(store: LiveChatSettingsStore) {
        self.store = store
        channel = store.settings.search.preferredChannel
        browserEngine = store.settings.search.browserEngine
    }
    var isChannelAvailable: Bool { store.settings.search.channels().contains(channel) }
    var hasKey: Bool {
        guard channel.requiresAPIKey else { return true }
        return channel == .deepSeek ? store.hasDeepSeekSearchKey : store.hasSearchKey
    }
    var needsSetup: Bool { !isChannelAvailable || (channel.requiresAPIKey && !hasKey) }
    var actionTitle: String {
        if isWorking { return stopRequested ? "正在停止…" : "停止搜索" }
        if needsSetup { return "配置搜索" }
        if channel == .browser { return "通过\(browserEngine.title)搜索" }
        return "通过 \(channel.title) 搜索"
    }
    func configurationChanged() {
        guard !isWorking else { return }
        browser?.stop(); browser = nil
        channel = store.settings.search.preferredChannel
        browserEngine = store.settings.search.browserEngine
        results = nil; selection = nil; message = nil
    }
    func channelChanged() {
        guard !isWorking else { return }
        results = nil; resultQuery = ""; resultChannel = nil; message = nil
        browser?.stop(); browser = nil
    }
    func selectBrowser(engine: DemoBrowserSearchEngine) {
        guard !isWorking else { return }
        channel = .browser
        browserEngine = engine
        channelChanged()
    }

    func run(interactions: LiveToolInteractionModel, browserSearch: DemoBrowserSearchHandler? = nil) {
        guard !isWorking else { return }
        message = nil
        do {
            guard isChannelAvailable else { throw DemoSearchError.disabled }
            let text = try DemoSearchQuery(query).text
            let configuration = store.settings.search
            let selectedChannel = channel
            if selectedChannel == .browser {
                browser = LabSearchBrowserModel(channel: .browser, provider: browserEngine.title,
                    query: text, url: try selectedChannel.initialURL(query: text, engine: browserEngine),
                    keepsSession: configuration.keepsBrowserSession, isUITesting: store.isUITesting)
                return
            }
            let input = try BoneWebSearchInput(query: text, count: 5)
            if selectedChannel == .deepSeek && text.unicodeScalars.count > 128 { throw DemoSearchError.invalidQuery }
            let key: String
            if selectedChannel.requiresAPIKey {
                key = selectedChannel == .deepSeek ? try store.deepSeekSearchKey() : try store.searchKey()
                guard !key.isEmpty else { throw DemoSearchError.missingKey }
            } else { key = "" }
            let route = DemoSearchRouter(configuration: configuration, channel: selectedChannel, apiKey: key,
                transport: store.isUITesting ? LiveToolsUITestWebTransport() : nil, browserSearch: browserSearch)
            let authorizationDetail = selectedChannel == .baiduWeb
                ? "允许在后台读取百度公开搜索结果？\n\(text)\n\n搜索词会发送至百度，仅读取有限公开结果，返回标题、来源、摘要和读取时间；不弹出网页，遇验证即停止，无需搜索 API Key。结果先保留在此页，选取并运行任务后才发给当前模型，模型用量仍按模型账户计。"
                : "允许通过 \(selectedChannel.title) 搜索？\n\(text)\n\n查询会发送至该搜索服务，API 可能计费。搜索结果暂时保留在此页，选取并运行任务后才发给模型。"
            let token = UUID(); generation = token
            results = nil; resultQuery = ""; resultChannel = nil; requestCount = 0
            isWorking = true; stopRequested = false
            worker = Task {
                defer { isWorking = false; stopRequested = false; worker = nil }
                do {
                    let authorized = try await interactions.handlers.authorize(.init(id: UUID(), title: "确认搜索",
                        detail: authorizationDetail))
                    guard authorized else { message = "已取消，本次没有发送搜索请求。"; return }
                    try Task.checkCancellation()
                    requestCount = 1
                    let output = try await route.search(input)
                    try Task.checkCancellation()
                    guard generation == token, !stopRequested else { throw CancellationError() }
                    results = output; resultQuery = text; resultChannel = selectedChannel
                    message = output.results.isEmpty ? "没有找到结果，可调整搜索词。" : nil
                } catch { message = Self.safeMessage(error) }
            }
        } catch { message = Self.safeMessage(error) }
    }
    func stop(interactions: LiveToolInteractionModel) {
        guard isWorking, !stopRequested else { return }
        stopRequested = true; interactions.cancel(); worker?.cancel()
    }
    func openResult(_ result: BoneWebSearchResult) {
        guard !isWorking, let url = URL(string: result.url) else { return }
        browser = LabSearchBrowserModel(channel: resultChannel ?? .browser,
            provider: resultChannel?.title ?? "来源网页", query: resultQuery,
            url: url, keepsSession: store.settings.search.keepsBrowserSession, isUITesting: store.isUITesting)
    }
    func selectResult(_ result: BoneWebSearchResult) {
        do {
            let value = try DemoSearchSelection(title: result.title, url: result.url, text: result.snippet,
                                                channel: resultChannel ?? .browser, provider: results?.provider ?? "")
            selection = .init(value: value)
        } catch { message = Self.safeMessage(error) }
    }
    func selectBrowserText(_ value: DemoSearchSelection) { selection = .init(value: value) }
    func confirmSelection(_ use: (DemoSearchSelection) -> Bool) {
        guard let selection else { return }
        if use(selection.value) { self.selection = nil; message = "内容已加入任务草稿，返回实验室后可查看并运行。" }
    }
    private static func safeMessage(_ error: any Error) -> String {
        if error is CancellationError || Task.isCancelled { return "搜索已停止，不会自动重试。" }
        if let error = error as? DemoSearchError { return error.message }
        if let error = error as? DemoBrowserSearchError { return error.message }
        if let error = error as? LiveChatKeychainError { return error.message }
        if let error = error as? BoneWebError {
            switch error {
            case .invalidConfiguration: return "搜索 Key 或通道配置无效，请检查搜索设置。"
            case .invalidInput: return "搜索参数无效，请缩短搜索词或检查页码。"
            case .responseTooLarge: return "搜索结果超过本次容量上限。"
            case .httpFailure: return "搜索服务未完成请求，请检查 Key、余额或稍后重试。"
            default: return "搜索请求未完成，可以调整搜索词或手动切换通道后再试。"
            }
        }
        return "搜索未完成，请检查配置后重试。"
    }
}
