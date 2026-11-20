import XCTest

final class SearchModuleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 120 }

    @MainActor func testSearchSwitchPreservesDraftAndHasNoAutomaticRequest() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.tabBars.buttons["实验室"].tap()
        let input = any("labTaskInput", app)
        reveal(input, app); input.tap(); input.typeText("Keep my original task.")
        app.buttons["labTaskKeyboardDone"].tap()
        let search = app.buttons["openLabSearch"]
        reveal(search, app); search.tap()
        XCTAssertTrue(app.buttons["performSearch"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        let query = any("searchQueryInput", app)
        query.tap(); query.typeText("Swift actor")
        app.buttons["searchKeyboardDone"].tap()
        let settings = app.buttons["searchSettingsEntry"]
        reveal(settings, app); settings.tap()
        let enabled = app.switches["searchEnabledToggle"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 10))
        if enabled.value as? String == "1" { enabled.tap() }
        app.buttons["saveNetworkSettings"].tap()
        XCTAssertTrue(app.navigationBars["搜索设置"].waitForNonExistence(timeout: 10))
        reveal(query, app)
        XCTAssertEqual(query.value as? String, "Swift actor")
        XCTAssertTrue(app.buttons["performSearch"].label.contains("配置搜索"))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        let back = app.buttons["searchReturnToTask"]
        reveal(back, app); back.tap()
        reveal(input, app)
        XCTAssertEqual(input.value as? String, "Keep my original task.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "search-disabled-draft-retained"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor func testWeatherQuestionPrefillsManualSearchWithoutDispatch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.tabBars.buttons["实验室"].tap()
        let task = any("labTaskInput", app)
        reveal(task, app); task.tap(); task.typeText("今天桐乡温度")
        app.buttons["labTaskKeyboardDone"].tap()
        let tools = any("labToolChoices", app)
        reveal(tools, app); tools.tap()
        let fetch = app.switches["webFetchToggle"]
        reveal(fetch, app)
        if fetch.value as? String != "1" { fetch.tap() }
        app.tabBars.buttons["对话"].tap()
        let manual = app.buttons["chatPrepareManualSearch"]
        reveal(manual, app); manual.tap()
        XCTAssertTrue(app.buttons["performSearch"].waitForExistence(timeout: 10))
        XCTAssertEqual(any("searchQueryInput", app).value as? String, "今天桐乡温度")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "browserSearchEnginePicker").firstMatch.exists)
        XCTAssertTrue(app.buttons["performSearch"].label.contains("百度"))
        XCTAssertTrue(app.buttons["performSearch"].isEnabled)
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
        let back = app.buttons["searchReturnToTask"]
        reveal(back, app); back.tap()
        reveal(task, app)
        XCTAssertEqual(task.value as? String, "今天桐乡温度")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "weather-query-manual-search-prefill"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testBaiduAnswerUsesPublicReaderAndReturnsToolSourceWithoutSearchKey() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--baidu-answer-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ui-test-key")
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
        let input = any("chatInput", app)
        XCTAssertEqual(input.value as? String, "今天桐乡温度")
        let action = app.buttons["chatBaiduAnswer"]
        reveal(action, app); action.tap()
        let allow = app.buttons["toolAuthorizationAllow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "无需搜索 API Key")).firstMatch.exists)
        allow.tap()
        XCTAssertTrue(any("baiduAnswerReader", app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        XCTAssertFalse(any("baiduAnswerWebView", app).exists)
        let reply = app.staticTexts["assistantMessage"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 35))
        XCTAssertTrue(reply.label.contains("离线模拟，非真实天气") && reply.label.contains("23℃"))
        XCTAssertFalse(allow.exists)
        XCTAssertTrue(app.staticTexts["已读取百度公开结果"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "baidu-answer-offline-tool-handoff"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor func testComposerEnablesBaiduWithoutAnyModelOrSearchKey() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--baidu-recovery-ui-test"]
        app.launch()
        let enable = app.buttons["composerEnableBaiduSearch"]
        XCTAssertTrue(enable.waitForExistence(timeout: 10))
        XCTAssertTrue(enable.label.contains("启用百度"))
        enable.tap()
        XCTAssertTrue(any("composerSearchStatus", app).label.contains("百度"))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
    }

    @MainActor func testStaticSearchFailureCanSwitchToBaiduWithoutDeepSeek() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--baidu-answer-ui-test", "--baidu-recovery-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap(); app.buttons["sharedModelSettings"].tap()
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ui-test-minimax-key")
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectionSettings"].label.contains("MiniMax"))
        app.buttons["sendMessage"].tap()
        let retry = app.buttons["chatToolFailureBaiduAnswer"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        reveal(retry, app); retry.tap()
        let newRun = app.buttons["confirmNewToolRun"]
        XCTAssertTrue(newRun.waitForExistence(timeout: 10)); newRun.tap()
        let allow = app.buttons["toolAuthorizationAllow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        let reply = app.staticTexts["assistantMessage"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 35))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        XCTAssertTrue(reply.label.contains("离线模拟，非真实天气"))
        XCTAssertTrue(any("composerSearchStatus", app).label.contains("百度"))
    }

    @MainActor func testRealPublicBaiduPageReadsResultsWithoutModelOrSearchKeys() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--baidu-public-page-ui-test"]
        app.launch()
        let search = app.buttons["performSearch"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap()
        let allow = app.buttons["toolAuthorizationAllow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10)); allow.tap()
        let summary = any("searchResultSummary", app)
        XCTAssertTrue(summary.waitForExistence(timeout: 35), "实际百度读取未完成；验证码或网络失败应保留真实原因。")
        XCTAssertTrue(summary.label.contains("百度") && summary.label.contains("1 条结果"))
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
        XCTAssertTrue(app.staticTexts["真实百度网页验收 · 不调用模型"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "baidu-real-public-page-no-api-keys"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    @MainActor private func any(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<7 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : app.frame.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 85 : app.frame.maxY - 90
            if element.exists {
                let frame = element.frame
                if frame.minY >= top && frame.maxY <= bottom && frame.height > 0 && element.isHittable { return }
                if frame.minY < top { app.swipeDown(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
            } else { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
}
