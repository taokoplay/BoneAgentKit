import SwiftUI
import WebKit
import Observation

/// WebKit stays in the iOS Host. It never scrapes a results page or submits a chat prompt.
@Observable @MainActor
final class LabSearchBrowserModel: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    nonisolated let id = UUID()
    let webView: WKWebView
    let channel: DemoSearchChannel
    let provider: String
    let query: String
    private let isUITesting: Bool
    private(set) var address = ""
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var message: String?
    private(set) var isSelecting = false
    @ObservationIgnored private var pageRevision = UUID()

    init(channel: DemoSearchChannel, provider: String, query: String, url: URL,
         keepsSession: Bool, isUITesting: Bool) {
        self.channel = channel
        self.provider = provider
        self.query = query
        self.isUITesting = isUITesting
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = keepsSession && !isUITesting ? .default() : .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if isUITesting {
            webView.loadHTMLString("<!doctype html><meta name='viewport' content='width=device-width'><title>界面测试网页</title><h1>离线界面测试</h1><p>测试资料可手动选择。未访问真实网站。</p>",
                                  baseURL: URL(string: "https://example.com/"))
        } else { webView.load(URLRequest(url: url)) }
    }

    func back() { if webView.canGoBack { webView.goBack() } }
    func forward() { if webView.canGoForward { webView.goForward() } }
    func reload() { message = nil; webView.reload() }
    func stop() { webView.stopLoading(); isLoading = false }
    func selectText() async throws -> DemoSearchSelection {
        guard !isSelecting, !isLoading, let source = webView.url?.absoluteString else { throw DemoSearchError.invalidSelection }
        isSelecting = true
        let revision = pageRevision
        let selectedTitle = webView.title ?? "网页选取内容"
        defer { isSelecting = false }
        // Read only the selection after an explicit user action; never innerText, cookies, forms or full DOM.
        let value = try await webView.evaluateJavaScript("String(window.getSelection() ? window.getSelection().toString() : '').slice(0, 8193)")
        try Task.checkCancellation()
        guard revision == pageRevision, webView.url?.absoluteString == source, !isLoading else {
            throw DemoSearchError.pageChanged
        }
        guard let text = value as? String else { throw DemoSearchError.invalidSelection }
        return try .init(title: String(selectedTitle.prefix(120)), url: source, text: text,
                         channel: channel, provider: provider)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageRevision = UUID(); isLoading = true; message = nil; update()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false; update() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { failed(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false; pageRevision = UUID(); message = "网页进程已结束，可点击重新加载。"
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, !isUITesting else {
            message = isUITesting ? "界面测试模式不访问网络。" : "仅支持在此页浏览 HTTPS 网页。"
            decisionHandler(.cancel); return
        }
        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            if navigationAction.navigationType == .linkActivated { webView.load(navigationAction.request) }
            else { message = "网页尝试打开新窗口，请使用当前页面中的链接。" }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }

    private func update() {
        address = webView.url?.absoluteString ?? ""
        title = webView.title ?? provider
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
    }
    private func failed(_ error: any Error) {
        isLoading = false; update()
        if (error as NSError).code != NSURLErrorCancelled { message = "网页未能加载，可重新加载或返回切换搜索方式。" }
    }
}

private struct SearchWebView: UIViewRepresentable {
    let model: LabSearchBrowserModel
    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: ()) { uiView.stopLoading() }
}

struct LabSearchBrowserView: View {
    let model: LabSearchBrowserModel
    let onSelected: (DemoSearchSelection) -> Void
    @State private var selecting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.address.isEmpty ? model.provider : model.address)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    .accessibilityIdentifier("searchBrowserAddress")
                if let message = error ?? model.message {
                    Text(message).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("searchBrowserError")
                }
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16).padding(.vertical, 8).background(LabStyle.surface)
            SearchWebView(model: model).accessibilityIdentifier("searchBrowserWebView")
        }
        .navigationTitle(model.provider)
        .navigationBarTitleDisplayMode(.inline)
        .background(LabStyle.canvas)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("后退", systemImage: "chevron.left", action: model.back).disabled(!model.canGoBack)
                Button("前进", systemImage: "chevron.right", action: model.forward).disabled(!model.canGoForward)
                if model.isLoading { Button("停止加载", systemImage: "xmark", action: model.stop) }
                else { Button("重新加载", systemImage: "arrow.clockwise", action: model.reload) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 6) {
                Button {
                    selecting = true; error = nil
                    Task { @MainActor in
                        defer { selecting = false }
                        do { onSelected(try await model.selectText()) }
                        catch let failure as DemoSearchError { self.error = failure.message }
                        catch { self.error = "无法读取所选文字，请重新长按选取。" }
                    }
                } label: { Label(selecting ? "正在读取选取内容…" : "使用选中的文字", systemImage: "text.badge.plus").frame(maxWidth: .infinity, minHeight: 44) }
                .buttonStyle(.borderedProminent).foregroundStyle(LabStyle.onAccent).controlSize(.large)
                .disabled(selecting || model.isLoading).accessibilityIdentifier("useSelectedSearchText")
                Text("先长按选择一小段文字，再预览并加入任务。不会自动读取整页。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
        }
        .onDisappear { model.stop() }
    }
}
