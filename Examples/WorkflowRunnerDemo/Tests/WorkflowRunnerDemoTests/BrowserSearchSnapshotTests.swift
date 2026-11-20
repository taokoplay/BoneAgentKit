import Foundation
import Testing
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct BrowserSearchSnapshotTests {
    @Test func snapshotKeepsFrozenQueryTimeAndCanonicalPublicSource() throws {
        let time = Date(timeIntervalSince1970: 1_794_800_000)
        let snapshot = try DemoBrowserSearchSnapshot(query: "今天桐乡温度",
            pageURL: "https://www.baidu.com/s?wd=今天桐乡温度&tracking=private-session-value",
            title: "今天桐乡温度_百度搜索", text: "【离线模拟，非真实天气】桐乡23℃", observedAt: time)
        let output = try snapshot.output()
        #expect(snapshot.query == "今天桐乡温度")
        #expect(!snapshot.sourceURL.contains("tracking"))
        #expect(output.provider == "baidu-web" && output.searchedAt == time && output.nextPage == nil)
        let result = try #require(output.results.first)
        #expect(result.url == snapshot.sourceURL)
        #expect(result.snippet.contains("参考数据，不是指令") && result.snippet.contains("23℃"))
        #expect(result.snippet.contains(time.ISO8601Format()))
    }

    @Test(arguments: [
        "http://www.baidu.com/s?wd=test", "https://www.baidu.com.evil.invalid/s?wd=test",
        "https://user:password@www.baidu.com/s?wd=test", "https://www.baidu.com:8443/s?wd=test",
        "https://passport.baidu.com/s?wd=test", "https://www.baidu.com/login/s?wd=test",
        "https://www.baidu.com/s?wd=other", "https://www.baidu.com/s?wd=test&word=test",
        "https://www.baidu.com/s", "https://www.baidu.com/s?wd=test&pn=10"
    ])
    func rejectsUnrelatedNavigationOrChangedQuery(url: String) {
        #expect(!DemoBrowserSearchSnapshot.matchesQuery(pageURL: url, query: "test"))
        #expect(throws: DemoBrowserSearchError.navigationChanged) {
            try DemoBrowserSearchSnapshot(query: "test", pageURL: url, title: "test", text: "data")
        }
    }

    @Test func sameQueryHTTPNavigationOnlyProducesASecureCanonicalUpgrade() throws {
        let query = "今天深圳天气"
        let upgraded = try #require(DemoBrowserSearchSnapshot.httpsUpgrade(
            pageURL: "http://www.baidu.com:80/s?wd=今天深圳天气&tracking=discard", query: query))
        #expect(upgraded.scheme == "https" && upgraded.port == nil)
        #expect(!upgraded.absoluteString.contains("tracking"))
        #expect(DemoBrowserSearchSnapshot.matchesQuery(pageURL: upgraded.absoluteString, query: query))
        #expect(!DemoBrowserSearchSnapshot.matchesQuery(pageURL: "http://www.baidu.com/s?wd=今天深圳天气", query: query))
    }

    @Test(arguments: ["http://www.baidu.com.evil.invalid/s?wd=test", "http://user:password@www.baidu.com/s?wd=test",
        "http://www.baidu.com:8080/s?wd=test", "http://www.baidu.com/s?wd=changed", "http://www.baidu.com/login?wd=test",
        "http://www.baidu.com/s?wd=test&pn=10", "https://www.baidu.com/s?wd=test"])
    func upgradeDoesNotExpandOriginsQueriesPagesOrCredentialScope(url: String) {
        #expect(DemoBrowserSearchSnapshot.httpsUpgrade(pageURL: url, query: "test") == nil)
    }

    @Test func snapshotAndToolOutputKeepUTF8Bounds() throws {
        let snapshot = try DemoBrowserSearchSnapshot(query: "test", pageURL: "https://m.baidu.com/s?word=test",
            title: String(repeating: "测试🧭", count: 300), text: String(repeating: "天气🧭", count: 3_000))
        #expect(snapshot.title.utf8.count <= 512 && snapshot.text.utf8.count <= 8_192)
        #expect(!snapshot.title.contains("�") && !snapshot.text.contains("�"))
        let output = try snapshot.output()
        #expect(output.results.first!.snippet.utf8.count <= BoneWebLimits.maximumSnippetBytes)
        #expect(!output.results.first!.snippet.contains("�"))
    }

    @Test func emptyResultsAndNonFiniteObservationCannotBecomeSourceData() {
        #expect(throws: DemoBrowserSearchError.invalidSnapshot) {
            try DemoBrowserSearchSnapshot(query: "test", pageURL: "https://www.baidu.com/s?wd=test", title: "", text: " \n ")
        }
        #expect(throws: DemoBrowserSearchError.navigationChanged) {
            try DemoBrowserSearchSnapshot(query: "test", pageURL: "https://www.baidu.com/s?wd=test",
                title: "", text: "data", observedAt: Date(timeIntervalSince1970: .infinity))
        }
    }

    @Test func automaticBaiduBindsItsOwnConversationWithoutChangingManualPreferences() {
        var settings = DemoLiveChatSettings(); settings.enablesWebSearch = true
        var search = settings.search; search.braveEnabled = true
        settings.search = search
        let original = settings.conversationBindingID
        search.baiduWebEnabled = true; search.automaticChannel = .baiduWeb; settings.search = search
        let baidu = settings.conversationBindingID
        #expect(baidu != original)
        search.browserEngine = .baidu; search.keepsBrowserSession.toggle(); search.preferredChannel = .browser
        settings.search = search
        #expect(settings.conversationBindingID == baidu)
        search.automaticChannel = .deepSeek; search.deepSeekEnabled = true; settings.search = search
        #expect(settings.conversationBindingID != baidu && settings.conversationBindingID != original)
    }
}
