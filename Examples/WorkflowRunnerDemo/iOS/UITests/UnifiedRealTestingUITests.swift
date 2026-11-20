import XCTest

final class UnifiedRealTestingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    @MainActor func testConnectionUsesSharedSetupAndKeepsConversation() throws {
        let app = launch()
        XCTAssertFalse(app.tabBars.buttons["场景测试"].exists)
        XCTAssertFalse(app.tabBars.buttons["Prompt 实验"].exists)
        configureModel(app)
        let chat = field("chatInput", app)
        chat.tap(); chat.typeText("Keep this conversation.")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        dismissKeyboard(app)
        openLab(app)
        select(.connection, app)
        run(app)
        assertVerdict("检查通过", app)
        XCTAssertEqual(app.staticTexts["validationReply"].label, "连接正常")
        capture("unified-connection-result", app)
        app.tabBars.buttons["对话"].tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantMessage").count, 1)
        XCTAssertTrue(app.staticTexts["userMessage"].label.contains("Keep this conversation."))
    }

    @MainActor func testCalculatorUsesRealToolAndPreservesTaskAcrossSetup() throws {
        let app = launch()
        openLab(app)
        select(.calculator, app)
        let original = field("labTaskInput", app).value as? String
        app.buttons["labRunTask"].tap()
        saveKey(app)
        XCTAssertEqual(field("labTaskInput", app).value as? String, original)
        run(app)
        assertVerdict("检查通过", app)
        XCTAssertTrue(app.staticTexts["validationReply"].label.contains("391"))
        let details = any("validationRequestDetails", app)
        reveal(details, app); details.tap()
        let evidence = app.staticTexts["validationCalculatorEvidence"]
        reveal(evidence, app)
        XCTAssertTrue(evidence.label.contains("391"))
        capture("unified-calculator-evidence", app)
    }

    @MainActor func testSharedInstructionsAndReviewAreClear() throws {
        let app = launch()
        configureModel(app)
        openLab(app)
        select(.instructions, app)
        let edit = app.buttons["validationEditInstructions"]
        reveal(edit, app); edit.tap()
        let instruction = field("sharedInstructionInput", app)
        instruction.tap(); instruction.typeText(" SharedInstructionMarker_4729")
        app.buttons["saveSharedInstructions"].tap()
        XCTAssertTrue(app.navigationBars["助手说明"].waitForNonExistence(timeout: 10))
        run(app)
        assertVerdict("已完成，待你检查", app)
        let details = any("validationRequestDetails", app)
        reveal(details, app); details.tap()
        let system = app.staticTexts["validationSystemPrompt"]
        reveal(system, app)
        XCTAssertTrue(system.label.contains("SharedInstructionMarker_4729"))
        capture("unified-shared-instructions", app)
        app.navigationBars["测试结果"].buttons.element(boundBy: 0).tap()
        let expected = field("validationExpectedText", app)
        reveal(expected, app); expected.tap(); expected.typeText("界面测试")
        dismissKeyboard(app)
        run(app)
        assertVerdict("检查通过", app)
    }

    @MainActor func testWrongResponseIsNotReportedAsPassed() throws {
        let app = launch(["--validation-fail"])
        configureModel(app)
        openLab(app); select(.connection, app); run(app)
        assertVerdict("检查未通过", app)
        capture("unified-failed-check", app)
    }

    @MainActor func testStopPreservesTaskAndPreventsConcurrentSend() throws {
        let app = launch(["--validation-wait"])
        configureModel(app)
        openLab(app); select(.connection, app); run(app)
        let stop = app.buttons["labRunTask"]
        expectation(for: NSPredicate(format: "label CONTAINS %@", "停止测试"), evaluatedWith: stop)
        waitForExpectations(timeout: 10)
        app.tabBars.buttons["对话"].tap()
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        openLab(app)
        stop.tap()
        XCTAssertTrue(app.staticTexts["validationError"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["validationVerdict"].exists)
        app.navigationBars["测试结果"].buttons.element(boundBy: 0).tap()
        let input = field("labTaskInput", app)
        reveal(input, app)
        XCTAssertTrue((input.value as? String)?.contains("连接正常") == true)
        XCTAssertTrue(app.buttons["labRunTask"].isEnabled)
    }

    @MainActor func testNetworkSettingsCanBeEditedAfterSetupInDarkLargeText() throws {
        let app = launch(["--ui-test-dark", "--ui-test-large-text"])
        app.buttons["modelSettings"].tap()
        let network = app.buttons["sharedNetworkSettings"]
        reveal(network, app); network.tap()
        let hosts = field("webAllowedHostsField", app)
        reveal(hosts, app); hosts.tap(); hosts.typeText("example.com")
        dismissKeyboard(app)
        let search = app.secureTextFields["searchAPIKeyField"]
        reveal(search, app); search.tap(); search.typeText("ui-test-search-key")
        dismissKeyboard(app)
        app.buttons["saveNetworkSettings"].tap()
        XCTAssertTrue(app.navigationBars["联网设置"].waitForNonExistence(timeout: 10))
        app.buttons["modelSettings"].tap()
        reveal(network, app); network.tap()
        reveal(hosts, app)
        XCTAssertEqual(hosts.value as? String, "example.com")
        XCTAssertTrue(app.buttons["saveNetworkSettings"].isEnabled)
        capture("unified-network-dark-large", app)
    }

    private enum Kind: String {
        case connection, calculator, instructions
        var title: String {
            switch self { case .connection: "模型回复"; case .calculator: "工具计算"; case .instructions: "助手说明" }
        }
    }
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"] + extra
        app.launch()
        return app
    }
    @MainActor private func configureModel(_ app: XCUIApplication) {
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        saveKey(app)
    }
    @MainActor private func saveKey(_ app: XCUIApplication) {
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        reveal(key, app); key.tap(); key.typeText("ui-test-key")
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
    }
    @MainActor private func openLab(_ app: XCUIApplication) {
        dismissKeyboard(app)
        app.tabBars.buttons["实验室"].tap()
        XCTAssertTrue(app.buttons["labRunTask"].waitForExistence(timeout: 10))
    }
    @MainActor private func select(_ kind: Kind, _ app: XCUIApplication) {
        let menu = app.buttons["validationTaskMenu"]
        reveal(menu, app); menu.tap()
        let option = app.buttons["validationTemplate_\(kind.rawValue)"]
        if option.waitForExistence(timeout: 2) { option.tap() } else { app.buttons[kind.title].tap() }
        if app.buttons["confirmValidationTemplate"].waitForExistence(timeout: 1) { app.buttons["confirmValidationTemplate"].tap() }
    }
    @MainActor private func run(_ app: XCUIApplication) {
        let button = app.buttons["labRunTask"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 10)
        button.tap()
    }
    @MainActor private func assertVerdict(_ expected: String, _ app: XCUIApplication) {
        let verdict = app.staticTexts["validationVerdict"]
        XCTAssertTrue(verdict.waitForExistence(timeout: 20))
        XCTAssertTrue(verdict.label.contains(expected))
    }
    @MainActor private func any(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor private func field(_ id: String, _ app: XCUIApplication) -> XCUIElement { any(id, app) }
    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        for id in ["dismissChatKeyboard", "labTaskKeyboardDone", "dismissSettingsKeyboard", "dismissToolSettingsKeyboard", "instructionKeyboardDone"] {
            let button = app.buttons[id]
            if button.exists && button.isHittable { button.tap(); return }
        }
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for _ in 0..<8 {
            let viewport = app.frame
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : viewport.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 85 : viewport.maxY - 90
            if element.exists {
                let rect = element.frame
                if rect.minY >= top && rect.maxY <= bottom && rect.height > 0 && element.isHittable { return }
                if rect.minY < top { app.swipeDown(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
            } else { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
