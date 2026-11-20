import XCTest

final class AgentLabInteractionFlowUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 150 }

    @MainActor
    func testExampleSurvivesModelSetupAndRunsSelectedTool() throws {
        let app = launch()
        openLab(app)
        setSwitch("calculatorToggle", on: true, app: app)
        let guide = app.buttons["labToolGuide_calculator"]
        reveal(guide, app: app); guide.tap()
        let example = app.staticTexts["toolGuideExample"]
        reveal(example, app: app)
        let expected = example.label
        let use = app.buttons["toolGuideUseExample"]
        reveal(use, app: app); use.tap()
        XCTAssertTrue(app.navigationBars["调用说明"].waitForNonExistence(timeout: 10))
        let input = taskInput(app)
        reveal(input, app: app)
        XCTAssertEqual(input.value as? String, expected)
        XCTAssertEqual(app.buttons["labRunTask"].label, "配置模型")
        app.buttons["labRunTask"].tap()
        saveModelKey(app)
        reveal(input, app: app)
        XCTAssertEqual(input.value as? String, expected)
        capture("lab-task-after-model-setup", app)
        app.buttons["labRunTask"].tap()
        assertToolReply(app)
        XCTAssertTrue(app.tabBars.buttons["对话"].isSelected)
        capture("lab-task-real-tool-result", app)
    }

    @MainActor
    func testResearchSelectionShowsMissingSetupAndReturnsToSameTask() throws {
        let app = launch()
        openLab(app)
        preset("research", app: app)
        let searchToggle = app.switches["webSearchToggle"]
        reveal(searchToggle, app: app)
        XCTAssertEqual(searchToggle.value as? String, "1")
        let input = taskInput(app)
        reveal(input, app: app); input.tap(); input.typeText("tool-test:search")
        dismissTaskKeyboard(app)
        let setup = app.buttons["labRequirement_searchKey"]
        reveal(setup, app: app, upward: false)
        setup.tap()
        fillNetwork(app)
        reveal(input, app: app)
        XCTAssertEqual(input.value as? String, "tool-test:search")
        XCTAssertEqual(app.buttons["labRunTask"].label, "配置模型")
        app.buttons["labRunTask"].tap()
        saveModelKey(app)
        capture("lab-research-ready", app)
        app.buttons["labRunTask"].tap()
        XCTAssertTrue(app.buttons["toolAuthorizationAllow"].waitForExistence(timeout: 15))
        app.buttons["toolAuthorizationAllow"].tap()
        assertToolReply(app)
    }

    @MainActor
    func testChangingToolsKeepsHistoryAndDraftUntilConfirmed() throws {
        let app = launch()
        app.buttons["modelSettings"].tap(); app.buttons["sharedModelSettings"].tap(); saveModelKey(app)
        sendChat("first question", app)
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        let input = chatInput(app)
        input.tap(); input.typeText("tool-test:time")
        openLab(app)
        setSwitch("dateTimeToggle", on: true, app: app)
        let result = app.buttons["labViewResult"]
        reveal(result, app: app); result.tap()
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantMessage").count, 1)
        XCTAssertEqual(input.value as? String, "tool-test:time")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["confirmNewToolRun"].waitForExistence(timeout: 10))
        app.alerts.buttons["取消"].tap()
        XCTAssertEqual(input.value as? String, "tool-test:time")
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantMessage").count, 1)
        app.buttons["sendMessage"].tap()
        app.buttons["confirmNewToolRun"].tap()
        assertToolReply(app)
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantMessage").count, 1)
        XCTAssertEqual(app.staticTexts["userMessage"].label, "你：tool-test:time")
        capture("lab-tool-change-confirmed", app)
    }

    @MainActor
    func testLocalResourceCanJoinTaskWithoutLosingDraft() throws {
        let app = launch()
        openLab(app)
        let input = taskInput(app)
        reveal(input, app: app); input.tap(); input.typeText("tool-test:resources")
        dismissTaskKeyboard(app)
        let resourceLab = app.buttons["textResourceLab"]
        reveal(resourceLab, app: app); resourceLab.tap()
        app.buttons["textResourceMakePreview"].tap()
        let use = app.buttons["useResourceInTask"]
        reveal(use, app: app); use.tap()
        XCTAssertTrue(app.navigationBars["文本资源"].waitForNonExistence(timeout: 10))
        reveal(input, app: app, upward: false)
        XCTAssertEqual(input.value as? String, "tool-test:resources")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chatTextAttachment").firstMatch.exists)
        XCTAssertFalse(app.staticTexts["userMessage"].exists)
        capture("lab-resource-added-to-task", app)
        app.buttons["labRunTask"].tap(); saveModelKey(app)
        app.buttons["labRunTask"].tap()
        assertToolReply(app)
    }

    @MainActor
    func testSpecialExperimentReturnsFromSetupWithItsInput() throws {
        let app = launch()
        openLab(app)
        let structured = app.buttons["structuredOutputLab"]
        reveal(structured, app: app); structured.tap()
        let source = app.descendants(matching: .any).matching(identifier: "structuredOutputSource").firstMatch
        reveal(source, app: app); source.tap(); source.typeText("Keep this source across setup.")
        app.buttons["structuredOutputKeyboardDone"].tap()
        let configure = app.buttons["structuredConfigureModel"]
        reveal(configure, app: app, upward: false); configure.tap()
        saveModelKey(app)
        reveal(source, app: app)
        XCTAssertEqual(source.value as? String, "Keep this source across setup.")
        app.buttons["structuredOutputRun"].tap()
        XCTAssertTrue(app.staticTexts["structuredOutputValidationOutcome"].waitForExistence(timeout: 10))
        capture("lab-special-input-retained", app)
    }

    @MainActor
    func testExampleReplacementCancellationKeepsDraftAndSelection() throws {
        let app = launch()
        openLab(app)
        let input = taskInput(app)
        reveal(input, app: app); input.tap(); input.typeText("keep my existing task")
        dismissTaskKeyboard(app)
        let guide = app.buttons["labToolGuide_calculator"]
        reveal(guide, app: app, upward: false); guide.tap()
        let use = app.buttons["toolGuideUseExample"]
        reveal(use, app: app); use.tap()
        XCTAssertTrue(app.alerts["替换当前任务草稿？"].waitForExistence(timeout: 10))
        app.alerts.buttons["保留草稿"].tap()
        app.buttons["closeToolGuide"].tap()
        reveal(input, app: app)
        XCTAssertEqual(input.value as? String, "keep my existing task")
        let selection = app.switches["calculatorToggle"]
        reveal(selection, app: app, upward: false)
        XCTAssertEqual(selection.value as? String, "0")
    }

    @MainActor
    func testStagedToolsSurviveRelaunchWithoutStartingRequest() throws {
        let app = launch()
        openLab(app)
        setSwitch("calculatorToggle", on: true, app: app)
        setSwitch("askUserToggle", on: true, app: app)
        app.terminate()
        app.launchArguments = ["--live-chat-ui-test", "--built-in-tools-ui-test", "--preserve-ui-test-state"]
        app.launch()
        openLab(app)
        for id in ["calculatorToggle", "askUserToggle"] {
            let toggle = app.switches[id]
            reveal(toggle, app: app)
            XCTAssertEqual(toggle.value as? String, "1")
        }
        XCTAssertFalse(app.buttons["stopMessage"].exists)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
    }

    @MainActor
    func testWorkflowUsesSelectedCalculatorAndKeepsPromptWhenOpeningTools() throws {
        let app = launch()
        openLab(app)
        setSwitch("calculatorToggle", on: true, app: app)
        let workflow = app.buttons["liveWorkflowLab"]
        reveal(workflow, app: app); workflow.tap()
        let prompt = app.descendants(matching: .any).matching(identifier: "workflowPrompt").firstMatch
        reveal(prompt, app: app)
        let original = prompt.value as? String
        let tools = app.buttons["workflowConfigureTools"]
        reveal(tools, app: app, upward: false); tools.tap()
        setSwitch("calculatorToggle", on: false, app: app)
        app.navigationBars["选择工具"].buttons.element(boundBy: 0).tap()
        XCTAssertEqual(prompt.value as? String, original)
        let run = app.buttons["workflowRun"]
        reveal(run, app: app); run.tap()
        let response = app.staticTexts["workflowFinalResponse"]
        reveal(response, app: app)
        XCTAssertTrue(response.label.contains("脚本验证完成"))
        capture("lab-workflow-scope", app)
    }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--built-in-tools-ui-test"]
        app.launch(); return app
    }
    @MainActor private func openLab(_ app: XCUIApplication) {
        if app.buttons["dismissChatKeyboard"].exists && app.buttons["dismissChatKeyboard"].isHittable { app.buttons["dismissChatKeyboard"].tap() }
        if app.buttons["labTaskKeyboardDone"].exists && app.buttons["labTaskKeyboardDone"].isHittable { app.buttons["labTaskKeyboardDone"].tap() }
        app.tabBars.buttons["实验室"].tap()
        XCTAssertTrue(app.buttons["labRunTask"].waitForExistence(timeout: 10))
        if !app.switches["calculatorToggle"].exists {
            let tools = app.descendants(matching: .any).matching(identifier: "labToolChoices").firstMatch
            reveal(tools, app: app); tools.tap()
        }
        if !app.buttons["textResourceLab"].exists {
            let more = app.descendants(matching: .any).matching(identifier: "moreLabCapabilities").firstMatch
            reveal(more, app: app); more.tap()
        }
    }
    @MainActor private func taskInput(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "labTaskInput").firstMatch
    }
    @MainActor private func chatInput(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
    }
    @MainActor private func dismissTaskKeyboard(_ app: XCUIApplication) {
        if app.buttons["labTaskKeyboardDone"].waitForExistence(timeout: 5) { app.buttons["labTaskKeyboardDone"].tap() }
    }
    @MainActor private func setSwitch(_ id: String, on: Bool, app: XCUIApplication) {
        let toggle = app.switches[id]
        reveal(toggle, app: app)
        if toggle.value as? String != (on ? "1" : "0") {
            toggle.tap()
        }
        expectation(for: NSPredicate(format: "value == %@", on ? "1" : "0"), evaluatedWith: toggle)
        waitForExpectations(timeout: 5)
    }
    @MainActor private func preset(_ name: String, app: XCUIApplication) {
        let menu = app.buttons["toolPresetMenu"]
        reveal(menu, app: app, upward: false); menu.tap()
        app.buttons["toolPreset_\(name)"].tap()
    }
    @MainActor private func saveModelKey(_ app: XCUIApplication) {
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10)); key.tap(); key.typeText("ui-test-key")
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
    }
    @MainActor private func fillNetwork(_ app: XCUIApplication) {
        let hosts = app.descendants(matching: .any).matching(identifier: "webAllowedHostsField").firstMatch
        reveal(hosts, app: app); hosts.tap(); hosts.typeText("example.com")
        app.buttons["dismissToolSettingsKeyboard"].tap()
        let key = app.secureTextFields["searchAPIKeyField"]
        reveal(key, app: app); key.tap(); key.typeText("ui-test-search-key")
        app.buttons["dismissToolSettingsKeyboard"].tap()
        app.buttons["saveNetworkSettings"].tap()
        XCTAssertTrue(app.navigationBars["联网设置"].waitForNonExistence(timeout: 10))
    }
    @MainActor private func sendChat(_ text: String, _ app: XCUIApplication) {
        let input = chatInput(app); input.tap(); input.typeText(text); app.buttons["sendMessage"].tap()
    }
    @MainActor private func assertToolReply(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["2 次推理 · 1 次工具调用"].exists)
    }
    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : app.frame.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 85 : app.frame.maxY - 90
            if element.exists {
                let rect = element.frame
                if rect.minY >= top && rect.maxY <= bottom && rect.height > 0 && element.isHittable { return }
                if rect.minY < top { app.swipeDown(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
            } else if upward { app.swipeUp(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let image = app.screenshot()
        try? image.pngRepresentation.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("agent-lab-\(name).png"))
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
