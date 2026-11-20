import Foundation
import Observation
import WebKit
import BoneAgentTools

/// A fresh, logged-out renderer for each explicitly authorized public Baidu query.
@Observable @MainActor
final class LiveBrowserSearchModel: NSObject, WKNavigationDelegate, WKUIDelegate {
    struct Active: Identifiable {
        let id: UUID
        let query: String
        let sourceURL: URL
        let webView: WKWebView
    }
    private(set) var active: Active?
    private(set) var lastSnapshot: DemoBrowserSearchSnapshot?
    private(set) var message: String?
    private(set) var lastReadWasUnpresented = false
    @ObservationIgnored private let usesOfflinePage: Bool
    @ObservationIgnored private var continuation: CheckedContinuation<BoneWebSearchOutput, any Error>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var extraction: Task<Void, Never>?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var initialNavigation: WKNavigation?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var hasRequestedHTTPSUpgrade = false

    init(isUITesting: Bool = false) {
        usesOfflinePage = isUITesting && !ProcessInfo.processInfo.arguments.contains("--baidu-public-page-ui-test")
        super.init()
    }

    var handler: DemoBrowserSearchHandler {
        { [weak self] input in
            guard let self else { throw DemoBrowserSearchError.unavailable }
            return try await self.read(input)
        }
    }

    private func read(_ input: BoneWebSearchInput) async throws -> BoneWebSearchOutput {
        try Task.checkCancellation()
        guard input.page == 0 else { throw DemoBrowserSearchError.unsupportedPage }
        guard active == nil else { throw DemoBrowserSearchError.busy }
        let query = try DemoSearchQuery(input.query).text
        let url = try DemoBrowserSearchEngine.baidu.url(query: query)
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.preferredContentMode = .desktop
                configuration.defaultWebpagePreferences.preferredHTTPSNavigationPolicy = .errorOnFailure
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                // A bounded viewport permits DOM layout without adding WebKit to any window or view.
                let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1_024, height: 768), configuration: configuration)
                // Request the same desktop WebKit layout that this reader's result selectors support.
                webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"
                webView.navigationDelegate = self
                webView.uiDelegate = self
                webView.allowsBackForwardNavigationGestures = false
                self.continuation = continuation
                lastSnapshot = nil; message = nil; started = false; initialNavigation = nil
                hasRequestedHTTPSUpgrade = false
                lastReadWasUnpresented = false
                revision = UUID()
                active = .init(id: id, query: query, sourceURL: url, webView: webView)
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(28)) } catch { return }
                    self?.finish(id: id, result: .failure(DemoBrowserSearchError.timedOut))
                }
                start(id: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id: id) }
        }
    }

    /// The task owns loading; no SwiftUI presentation or visible browser is required.
    private func start(id: UUID) {
        guard let active, active.id == id, !started else { return }
        started = true
        if usesOfflinePage {
            initialNavigation = active.webView.loadHTMLString("""
                <!doctype html><meta name="viewport" content="width=device-width"><title>百度网页问答离线测试</title>
                <div id="content_left"><h1>今天桐乡温度</h1><p>离线模拟，非真实天气：桐乡 23℃。仅验证结果交给模型的链路。</p></div>
                """, baseURL: nil)
        } else { initialNavigation = active.webView.load(URLRequest(url: active.sourceURL, timeoutInterval: 25)) }
    }

    func cancel() { if let id = active?.id { cancel(id: id) } }
    func clear() { cancel(); lastSnapshot = nil; message = nil }
    func cancel(id: UUID) { finish(id: id, result: .failure(CancellationError())) }

    private func finish(id: UUID, result: Result<BoneWebSearchOutput, any Error>) {
        guard let active, active.id == id else { return }
        let continuation = self.continuation
        lastReadWasUnpresented = active.webView.superview == nil && active.webView.window == nil
        initialNavigation = nil
        self.continuation = nil
        self.active = nil
        deadline?.cancel(); deadline = nil
        extraction?.cancel(); extraction = nil
        active.webView.navigationDelegate = nil; active.webView.uiDelegate = nil
        active.webView.stopLoading()
        if case .failure(let error) = result {
            message = (error as? DemoBrowserSearchError)?.message ?? "本次百度网页读取已停止。"
        }
        continuation?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let active, active.webView === webView else { return }
        guard navigation === initialNavigation else {
            traceNavigation(stage: "initial-navigation", url: webView.url)
            finish(id: active.id, result: .failure(DemoBrowserSearchError.navigationChanged)); return
        }
        revision = UUID(); extraction?.cancel(); extraction = nil
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { startExtraction(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { startExtraction(webView) }

    private func startExtraction(_ webView: WKWebView) {
        guard let request = active, request.webView === webView, extraction == nil else { return }
        let expectedRevision = revision
        extraction = Task { [weak self] in
            guard let self else { return }
            do {
                var previous = ""
                var stable = 0
                for _ in 0..<36 {
                    try await Task.sleep(for: .milliseconds(500))
                    try Task.checkCancellation()
                    guard active?.id == request.id, revision == expectedRevision else { return }
                    let value = try await extract(webView)
                    try Task.checkCancellation()
                    guard active?.id == request.id, revision == expectedRevision else { return }
                    let actualURL = webView.url?.absoluteString ?? ""
                    guard usesOfflinePage ? actualURL == "about:blank" : DemoBrowserSearchSnapshot.matchesQuery(pageURL: actualURL, query: request.query) else {
                        traceNavigation(stage: "extraction-url", url: webView.url)
                        throw DemoBrowserSearchError.navigationChanged
                    }
                    if value.status == "verification" { throw DemoBrowserSearchError.verificationRequired }
                    guard value.status == "ready", !value.text.isEmpty else { continue }
                    stable = value.text == previous ? stable + 1 : 0
                    previous = value.text
                    // Allow asynchronously rendered cards to settle before taking a bounded snapshot.
                    guard stable >= 2 else { continue }
                    let snapshot = try DemoBrowserSearchSnapshot(query: request.query,
                        pageURL: usesOfflinePage ? request.sourceURL.absoluteString : actualURL,
                        title: value.title, text: value.text)
                    let output = try snapshot.output()
                    lastSnapshot = snapshot
                    finish(id: request.id, result: .success(output))
                    return
                }
                throw DemoBrowserSearchError.invalidSnapshot
            } catch is CancellationError {
                // The owner (cancel, deadline or navigation) settles the continuation.
            } catch {
                finish(id: request.id, result: .failure(error as? DemoBrowserSearchError ?? .invalidSnapshot))
            }
        }
    }

    private struct Extracted: Sendable { let status: String; let title: String; let text: String }
    private func extract(_ webView: WKWebView) async throws -> Extracted {
        try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript(DemoBrowserSearchExtraction.script, arguments: [:],
                in: nil, in: .defaultClient) { @MainActor result in
                switch result {
                case .success(let value):
                    guard let value = value as? [String: Any], let status = value["status"] as? String,
                          let title = value["title"] as? String, let text = value["text"] as? String else {
                        continuation.resume(throwing: DemoBrowserSearchError.invalidSnapshot); return
                    }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") {
                        let state = ["ready", "waiting", "verification"].contains(status) ? status : "other"
                        print("BAIDU_PUBLIC_EXTRACT status=\(state) bytes=\(text.utf8.count) root=\(value["rootPresent"] as? Bool ?? true) mobile=\(value["mobilePage"] as? Bool ?? false) home=\(value["homePage"] as? Bool ?? false)")
                    }
                    #endif
                    continuation.resume(returning: .init(status: status, title: title, text: text))
                case .failure(let error):
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") {
                        print("BAIDU_PUBLIC_SCRIPT_FAILURE code=\((error as NSError).code)")
                    }
                    #endif
                    continuation.resume(throwing: DemoBrowserSearchError.invalidSnapshot)
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let active, active.webView === webView, let url = navigationAction.request.url else {
            decisionHandler(.cancel); return
        }
        guard navigationAction.targetFrame?.isMainFrame == true else { decisionHandler(.cancel); return }
        if usesOfflinePage && url.absoluteString == "about:blank" { decisionHandler(.allow); return }
        guard navigationAction.navigationType == .other else {
            traceNavigation(stage: "action-type", url: url, type: navigationAction.navigationType.rawValue)
            decisionHandler(.cancel)
            finish(id: active.id, result: .failure(DemoBrowserSearchError.navigationChanged)); return
        }
        if !usesOfflinePage, let secureURL = DemoBrowserSearchSnapshot.httpsUpgrade(pageURL: url.absoluteString, query: active.query) {
            decisionHandler(.cancel)
            // A same-query downgrade must not discard the already rendered secure document.
            if let current = webView.url, extraction != nil,
               DemoBrowserSearchSnapshot.matchesQuery(pageURL: current.absoluteString, query: active.query) { return }
            guard !hasRequestedHTTPSUpgrade else {
                finish(id: active.id, result: .failure(DemoBrowserSearchError.navigationChanged)); return
            }
            hasRequestedHTTPSUpgrade = true
            initialNavigation = webView.load(URLRequest(url: secureURL, timeoutInterval: 25))
            return
        }
        guard !usesOfflinePage, DemoBrowserSearchSnapshot.matchesQuery(pageURL: url.absoluteString, query: active.query) else {
            traceNavigation(stage: "action-url", url: url, type: navigationAction.navigationType.rawValue)
            let host = url.host?.lowercased() ?? ""
            let needsVerification = host == "wappass.baidu.com" || host == "passport.baidu.com" ||
                (DemoBrowserSearchSnapshot.hosts.contains(host) && url.path.lowercased().contains("verify"))
            decisionHandler(.cancel)
            finish(id: active.id, result: .failure(needsVerification ? DemoBrowserSearchError.verificationRequired : .navigationChanged))
            return
        }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let response = navigationResponse.response as? HTTPURLResponse,
           response.statusCode != 200 {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") {
                print("BAIDU_PUBLIC_HTTP_FAILURE status=\(response.statusCode)")
            }
            #endif
            decisionHandler(.cancel)
            if let id = active?.id { finish(id: id, result: .failure(DemoBrowserSearchError.invalidSnapshot)) }
        } else { decisionHandler(.allow) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { fail(webView, error: error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { fail(webView, error: error) }
    private func traceNavigation(stage: String, url: URL?, type: Int = -99) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("--run-authorized-public-baidu-diagnostic") else { return }
        let query = active?.query ?? ""
        let location = url?.absoluteString == "about:blank" ? "blank" :
            (url == nil ? "unset" : (DemoBrowserSearchSnapshot.matchesQuery(pageURL: url!.absoluteString, query: query) ? "matching-search" : "other"))
        let host = url?.host?.lowercased() ?? ""
        let origin = DemoBrowserSearchSnapshot.hosts.contains(host) ? host : "other"
        let path = ["/", "/s", "/baidu"].contains(url?.path ?? "") ? url!.path : "other"
        let parts = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let terms = (parts?.queryItems ?? []).filter { ["wd", "word"].contains($0.name.lowercased()) }
        let pages = (parts?.queryItems ?? []).filter { $0.name.lowercased() == "pn" }
        let matches = terms.filter { $0.value == query }.count
        let decodedMatches = terms.filter { $0.value?.removingPercentEncoding == query }.count
        let https = parts?.scheme?.lowercased() == "https"
        let credentials = parts?.user != nil || parts?.password != nil
        print("BAIDU_PUBLIC_NAVIGATION_INPUT https=\(https) credentials=\(credentials) defaultPort=\(parts?.port == nil || parts?.port == 443) terms=\(terms.count) matches=\(matches) decodedMatches=\(decodedMatches) pages=\(pages.count) pageZero=\(pages.allSatisfy { $0.value == "0" }) bytes=\(url?.absoluteString.utf8.count ?? 0)")
        print("BAIDU_PUBLIC_NAVIGATION_BLOCK stage=\(stage) location=\(location) origin=\(origin) path=\(path) type=\(type) initialAssigned=\(initialNavigation != nil)")
        #endif
    }

    private func fail(_ webView: WKWebView, error: any Error) {
        guard let active, active.webView === webView, (error as NSError).code != NSURLErrorCancelled else { return }
        finish(id: active.id, result: .failure(DemoBrowserSearchError.unavailable))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let active, active.webView === webView else { return }
        finish(id: active.id, result: .failure(DemoBrowserSearchError.unavailable))
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
}
