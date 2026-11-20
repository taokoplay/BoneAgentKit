import XCTest

final class BoneBuiltInToolsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 150 }

    @MainActor
    func testBasicPresetSingleAndMultipleChoice() throws {
        let app = launch()
        configure(in: app)
        send("tool-test:single", in: app)
        XCTAssertTrue(app.buttons["toolOption_b"].waitForExistence(timeout: 15))
        app.buttons["toolOption_b"].tap()
        capture("tools-single-choice", app: app)
        app.buttons["toolQuestionSubmit"].tap()
        assertCompleted(in: app)
        freshConversation(in: app)
        send("tool-test:multiple", in: app)
        XCTAssertTrue(app.buttons["toolOption_a"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["toolQuestionSubmit"].isEnabled)
        app.buttons["toolOption_a"].tap()
        app.buttons["toolOption_c"].tap()
        capture("tools-multiple-choice", app: app)
        app.buttons["toolQuestionSubmit"].tap()
        assertCompleted(in: app)
    }

    @MainActor
    func testTextAnswerAndCancellation() throws {
        let app = launch()
        configure(in: app)
        send("tool-test:text", in: app)
        let text = app.descendants(matching: .any).matching(identifier: "toolQuestionText").firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 15))
        text.tap()
        text.typeText("A real answer from the test user.")
        app.buttons["dismissToolQuestionKeyboard"].tap()
        capture("tools-text-answer", app: app)
        app.buttons["toolQuestionSubmit"].tap()
        assertCompleted(in: app)
        freshConversation(in: app)
        send("tool-test:single", in: app)
        XCTAssertTrue(app.buttons["toolQuestionCancel"].waitForExistence(timeout: 15))
        app.buttons["toolQuestionCancel"].tap()
        XCTAssertTrue(app.buttons["restartChat"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
        capture("tools-question-cancelled", app: app)
    }

    @MainActor
    func testResearchToolsRequireEachAuthorization() throws {
        let app = launch()
        configure(in: app, research: true)
        send("tool-test:fetch", in: app)
        XCTAssertTrue(app.buttons["toolAuthorizationAllow"].waitForExistence(timeout: 15))
        capture("tools-web-authorization", app: app)
        app.buttons["toolAuthorizationAllow"].tap()
        assertCompleted(in: app)
        freshConversation(in: app)
        send("tool-test:search", in: app)
        XCTAssertTrue(app.buttons["toolAuthorizationAllow"].waitForExistence(timeout: 15))
        capture("tools-search-authorization", app: app)
        app.buttons["toolAuthorizationAllow"].tap()
        assertCompleted(in: app)
        freshConversation(in: app)
        send("tool-test:fetch", in: app)
        XCTAssertTrue(app.buttons["toolAuthorizationDeny"].waitForExistence(timeout: 15))
        app.buttons["toolAuthorizationDeny"].tap()
        XCTAssertTrue(app.buttons["restartChat"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
    }

    @MainActor
    func testToolSettingsInDarkLargeType() throws {
        let app = launch(extra: ["--ui-test-dark", "--ui-test-large-text"])
        openTools(in: app)
        selectPreset("resources", in: app)
        let resources = app.switches["resourcesToggle"]
        reveal(resources, in: app)
        XCTAssertEqual(resources.value as? String, "1")
        capture("tools-settings-dark-large", app: app)
    }

    @MainActor
    func testBlockedWebsiteShowsCauseAndPreservesNextDraft() throws {
        let app = launch()
        openTools(in: app)
        selectPreset("basic", in: app)
        let fetch = app.switches["webFetchToggle"]
        reveal(fetch, in: app); fetch.tap()
        let setup = app.buttons["labToolSetup_webFetch"]
        reveal(setup, in: app); setup.tap()
        let hosts = app.descendants(matching: .any).matching(identifier: "webAllowedHostsField").firstMatch
        reveal(hosts, in: app); hosts.tap(); hosts.typeText("example.com")
        app.buttons["dismissToolSettingsKeyboard"].tap()
        app.buttons["saveNetworkSettings"].tap()
        XCTAssertTrue(app.navigationBars["搜索设置"].waitForNonExistence(timeout: 10))
        let result = app.buttons["labViewResult"]
        reveal(result, in: app); result.tap()
        send("tool-test:blocked-fetch", in: app)
        let detail = app.staticTexts["chatToolFailureDetail"]
        XCTAssertTrue(detail.waitForExistence(timeout: 15))
        XCTAssertTrue(detail.label.contains("不在允许读取的域名"))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap(); input.typeText("Keep my next draft.")
        app.buttons["dismissChatKeyboard"].tap()
        let recover = app.buttons["recoverFailedTask"]
        reveal(recover, in: app); recover.tap()
        XCTAssertEqual(input.value as? String, "Keep my next draft.")
        let retained = app.descendants(matching: .any).matching(identifier: "unsentTask").firstMatch
        reveal(retained, in: app); retained.tap()
        XCTAssertTrue(app.staticTexts["tool-test:blocked-fetch"].exists)
        capture("tools-blocked-site-recovery", app: app)
        let search = app.buttons["chatToolFailureSearch"]
        reveal(search, in: app, upwards: false); search.tap()
        XCTAssertTrue(app.buttons["performSearch"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["toolAuthorizationAllow"].exists)
        app.tabBars.buttons["对话"].tap()
        let restart = app.buttons["restartChat"]
        reveal(restart, in: app); restart.tap()
        XCTAssertTrue(app.staticTexts["chatError"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "Keep my next draft.")
        XCTAssertTrue(retained.exists)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--built-in-tools-ui-test"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openTools(in app: XCUIApplication) {
        XCTAssertTrue(app.buttons["modelSettings"].waitForExistence(timeout: 10))
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap(); key.typeText("ui-test-key")
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
        app.tabBars.buttons["实验室"].tap()
        XCTAssertTrue(app.buttons["labRunTask"].waitForExistence(timeout: 10))
        let tools = app.descendants(matching: .any).matching(identifier: "labToolChoices").firstMatch
        reveal(tools, in: app); tools.tap()
    }

    @MainActor
    private func selectPreset(_ id: String, in app: XCUIApplication) {
        let menu = app.buttons["toolPresetMenu"]
        reveal(menu, in: app, upwards: false)
        menu.tap()
        app.buttons["toolPreset_\(id)"].tap()
    }

    @MainActor
    private func configure(in app: XCUIApplication, research: Bool = false) {
        openTools(in: app)
        selectPreset(research ? "research" : "basic", in: app)
        if research {
            let setup = app.buttons["labToolSetup_webFetch"]
            reveal(setup, in: app)
            setup.tap()
            let hosts = app.descendants(matching: .any).matching(identifier: "webAllowedHostsField").firstMatch
            reveal(hosts, in: app)
            hosts.tap(); hosts.typeText("example.com")
            app.buttons["dismissToolSettingsKeyboard"].tap()
            let key = app.secureTextFields["searchAPIKeyField"]
            reveal(key, in: app)
            key.tap(); key.typeText("ui-test-search-key")
            app.buttons["dismissToolSettingsKeyboard"].tap()
            app.buttons["saveNetworkSettings"].tap()
            XCTAssertTrue(app.navigationBars["联网设置"].waitForNonExistence(timeout: 10))
        }
        capture(research ? "tools-research-preset" : "tools-basic-preset", app: app)
        let result = app.buttons["labViewResult"]
        reveal(result, in: app)
        result.tap()
        XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func send(_ message: String, in app: XCUIApplication) {
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap(); input.typeText(message)
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        app.buttons["sendMessage"].tap()
    }

    @MainActor
    private func assertCompleted(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 次推理 · 1 次工具调用"].exists)
    }

    @MainActor
    private func freshConversation(in app: XCUIApplication) {
        app.buttons["newConversation"].tap()
        app.buttons["开始新对话"].tap()
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upwards: Bool = true) {
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : app.frame.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 85 : app.frame.maxY - 90
            if element.exists {
                let rect = element.frame
                if rect.minY >= top && rect.maxY <= bottom && rect.height > 0 && element.isHittable { return }
                if rect.minY < top { app.swipeDown(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
            } else if upwards { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor
    private func capture(_ name: String, app: XCUIApplication) {
        let image = app.screenshot()
        try? image.pngRepresentation.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-lab-\(name).png"))
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
