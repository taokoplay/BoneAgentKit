import XCTest

final class BoneAgentLabUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 150 }

    @MainActor
    func testDarkModeAndLargeType() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--ui-test-dark", "--ui-test-large-text"]
        app.launch()
        capture("chat-empty-dark-large")
        app.buttons["modelSettings"].tap()
        XCTAssertTrue(app.buttons["sharedModelSettings"].waitForExistence(timeout: 10))
        capture("shared-settings-dark-large")
        app.buttons["sharedModelSettings"].tap()
        XCTAssertTrue(app.secureTextFields["apiKeyField"].waitForExistence(timeout: 10))
        capture("settings-dark-large")
        app.buttons["cancelModelSettings"].tap()
        app.buttons["closeUnifiedSettings"].tap()
        app.tabBars.buttons["实验室"].tap()
        XCTAssertTrue(app.buttons["labRunTask"].waitForExistence(timeout: 10))
        capture("laboratory-dark-large")
    }

    @MainActor
    func testLiveChatSettingsAndReply() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        configureChat(in: app)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap()
        input.typeText("hello")
        capture("chat-keyboard")
        app.buttons["sendMessage"].tap()
        let reply = app.staticTexts["assistantMessage"]
        XCTAssertTrue(reply.waitForExistence(timeout: 15))
        XCTAssertEqual(reply.label, "UI 测试回复（未联网）")
        XCTAssertTrue(app.staticTexts["1 次推理 · 0 次工具调用"].exists)
        XCTAssertTrue(reply.isHittable)
        XCTAssertTrue(input.isEnabled)
        app.buttons["收起键盘"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["latestMessage"].exists, "New content should stay followed until the user scrolls away")
        capture("live-chat-reply-fixture")
        let copy = app.buttons["copyReply"]
        XCTAssertTrue(copy.exists)
        copy.tap()
        XCTAssertEqual(copy.label, "已复制")
        app.buttons["newConversation"].tap()
        app.buttons["取消"].tap()
        XCTAssertTrue(reply.exists, "Cancelling a new conversation keeps messages")
        app.buttons["newConversation"].tap()
        app.buttons["开始新对话"].tap()
        XCTAssertTrue(reply.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testLiveChatCancellationRequiresNewConversation() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--live-chat-wait"]
        app.launch()
        configureChat(in: app)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap()
        input.typeText("cancel this request")
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled)
        capture("chat-before-cancel-request")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["userMessage"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stopMessage"].waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled)
        input.tap()
        input.typeText("next draft")
        app.buttons["stopMessage"].tap()
        XCTAssertTrue(app.buttons["restartChat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["sendMessage"].isEnabled, "A new-session send remains available with confirmation")
        app.buttons["restartChat"].tap()
        XCTAssertTrue(app.staticTexts["userMessage"].waitForNonExistence(timeout: 10))
        XCTAssertEqual(input.value as? String, "next draft")
    }

    @MainActor
    func testSDKProviderAndLocalModelSelection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        app.buttons["providerPicker"].tap()
        XCTAssertTrue(app.buttons["sdkProvider_OpenAI"].waitForExistence(timeout: 10))
        capture("sdk-provider-icons")
        app.buttons["sdkProvider_OpenAI"].tap()
        app.buttons["chooseSDKModel"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sdkModel_")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["sdkModelSource"].label.contains("SDK 内置"))
        let selectedID = String(row.identifier.dropFirst("sdkModel_".count))
        capture("sdk-local-model-icons")
        row.tap()
        XCTAssertEqual(app.textFields["modelIDField"].value as? String, selectedID)
    }

    @MainActor
    func testSDKUpstreamModelRefresh() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        app.buttons["providerPicker"].tap()
        app.buttons["sdkProvider_OpenAI"].tap()
        let key = app.secureTextFields["apiKeyField"]
        key.tap()
        key.typeText("ui-test-key")
        app.buttons["dismissSettingsKeyboard"].tap()
        let choose = app.buttons["chooseSDKModel"]
        reveal(choose, in: app)
        choose.tap()
        XCTAssertTrue(app.buttons["refreshSDKModels"].waitForExistence(timeout: 10))
        app.buttons["refreshSDKModels"].tap()
        let discovered = app.buttons["sdkModel_ui-discovered-model"]
        XCTAssertTrue(discovered.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["sdkModelSource"].label.contains("上游已更新"))
        capture("sdk-upstream-model-list")
        discovered.tap()
        XCTAssertEqual(app.textFields["modelIDField"].value as? String, "ui-discovered-model")
        XCTAssertTrue(app.buttons["saveModelSettings"].isEnabled, "Selecting a model must preserve the unsaved key")
    }

    @MainActor
    func testZhipuLoadsAccountModelsAndWaitsForSelection() {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        app.buttons["providerPicker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Zhipu")
        let provider = app.buttons["sdkProvider_Zhipu"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.tap()

        let modelID = app.textFields["modelIDField"]
        XCTAssertEqual(modelID.value as? String, modelID.placeholderValue)
        let choose = app.buttons["chooseSDKModel"]
        reveal(choose, in: app)
        choose.tap()
        let status = app.staticTexts["sdkModelSource"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "未填写 API Key")
        XCTAssertFalse(app.buttons["refreshSDKModels"].isEnabled)
        XCTAssertFalse(app.buttons["sdkModel_glm-5.2"].exists)
        app.buttons["手动填写 ID"].tap()

        let key = app.secureTextFields["apiKeyField"]
        reveal(key, in: app)
        key.tap()
        key.typeText("ui-test-key")
        app.buttons["dismissSettingsKeyboard"].tap()
        reveal(choose, in: app)
        choose.tap()
        let glm = app.buttons["sdkModel_glm-5.3"]
        let flash = app.buttons["sdkModel_glm-5.3-flash"]
        XCTAssertTrue(glm.waitForExistence(timeout: 15))
        XCTAssertTrue(flash.exists)
        XCTAssertTrue(status.label.contains("UI 测试替身"))
        XCTAssertNotEqual(glm.value as? String, "已选择")
        XCTAssertNotEqual(flash.value as? String, "已选择")
        XCTAssertFalse(app.buttons["sdkModel_glm-5.2"].exists)
        flash.tap()
        XCTAssertEqual(modelID.value as? String, "glm-5.3-flash")
    }

    @MainActor
    func testOpenAICompatibleLoadsModelsWithoutPreselection() {
        checkCompatibleModelSelection(providerID: "OpenAICompatible")
    }

    @MainActor
    func testAnthropicCompatibleLoadsModelsWithoutPreselection() {
        checkCompatibleModelSelection(providerID: "AnthropicCompatible")
    }

    @MainActor
    private func checkCompatibleModelSelection(providerID: String) {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        app.buttons["providerPicker"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText(providerID)
        let provider = app.buttons["sdkProvider_\(providerID)"]
        XCTAssertTrue(provider.waitForExistence(timeout: 10))
        provider.tap()

        let modelID = app.textFields["modelIDField"]
        XCTAssertEqual(modelID.value as? String, modelID.placeholderValue)
        let advanced = app.descendants(matching: .any).matching(identifier: "advancedSettings").firstMatch
        reveal(advanced, in: app)
        advanced.tap()
        let address = app.textFields["baseURLField"]
        reveal(address, in: app)
        address.tap()
        address.typeText("https://catalog-fixture.invalid/proxy/v1")
        app.buttons["dismissSettingsKeyboard"].tap()

        let choose = app.buttons["chooseSDKModel"]
        for _ in 0..<4 where !choose.exists || !choose.isHittable { app.swipeDown(velocity: .fast) }
        XCTAssertTrue(choose.exists && choose.isHittable)
        choose.tap()
        let model = app.buttons["sdkModel_ui-gateway-model"]
        XCTAssertTrue(model.waitForExistence(timeout: 15))
        XCTAssertNotEqual(model.value as? String, "已选择")
        XCTAssertTrue(app.staticTexts["sdkModelSource"].label.contains("UI 测试替身"))
        model.tap()
        XCTAssertEqual(modelID.value as? String, "ui-gateway-model")
    }

    @MainActor
    func testSettingsDraftProtection() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        capture("chat-empty")
        app.buttons["connectionSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        XCTAssertTrue(app.secureTextFields["apiKeyField"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["baseURLField"].exists)
        capture("model-settings")
        let key = app.secureTextFields["apiKeyField"]
        key.tap()
        key.typeText("ui-test-key")
        app.buttons["cancelModelSettings"].tap()
        XCTAssertTrue(app.buttons["继续编辑"].waitForExistence(timeout: 5))
        app.buttons["继续编辑"].tap()
        XCTAssertTrue(app.buttons["saveModelSettings"].isEnabled)
        app.buttons["cancelModelSettings"].tap()
        app.buttons["放弃更改"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 5))
        app.buttons["sharedModelSettings"].tap()
        XCTAssertFalse(app.buttons["saveModelSettings"].isEnabled, "Discarding must not persist the key")
        let advanced = app.descendants(matching: .any).matching(identifier: "advancedSettings").firstMatch
        reveal(advanced, in: app)
        advanced.tap()
        let address = app.textFields["baseURLField"]
        reveal(address, in: app)
        XCTAssertTrue(address.exists)
        capture("settings-advanced")
    }

    @MainActor
    func testStreamingTwoTurnsAndSDKStatistics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--live-chat-stream-slow"]
        app.launch()
        configureChat(in: app)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap()
        input.typeText("first turn")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["streamingReply"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["copyReply"].exists)
        capture("streaming-draft")
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        input.tap()
        input.typeText("second turn")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["streamingReply"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts.matching(identifier: "assistantMessage").count, 2)
        app.buttons["chatStatistics"].tap()
        XCTAssertTrue(app.navigationBars["运行统计"].waitForExistence(timeout: 10))
        capture("sdk-statistics-before-scroll")
        let contextSource = app.descendants(matching: .any).matching(identifier: "contextTokenSource").firstMatch
        reveal(contextSource, in: app)
        XCTAssertTrue(contextSource.exists)
        capture("sdk-statistics")
        app.navigationBars["运行统计"].buttons["完成"].tap()
    }

    @MainActor
    func testCompletedConversationRestoresWithoutDispatch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        configureChat(in: app, preservesConversation: true)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap()
        input.typeText("persisted question")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["stopMessage"].waitForNonExistence(timeout: 10))
        app.terminate()
        app.launchArguments = ["--live-chat-ui-test", "--preserve-ui-test-state", "--live-chat-wait"]
        app.launch()
        capture("conversation-after-reopen")
        XCTAssertTrue(app.staticTexts["assistantMessage"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["chatNotice"].label.contains("已恢复本机对话"))
        XCTAssertFalse(app.buttons["stopMessage"].exists)
        capture("restored-conversation")
    }

    @MainActor
    func testInterruptedConversationRestoresLocked() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--live-chat-wait"]
        app.launch()
        configureChat(in: app, preservesConversation: true)
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        input.tap()
        input.typeText("interrupted question")
        app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts["userMessage"].waitForExistence(timeout: 10))
        app.buttons["stopMessage"].tap()
        XCTAssertTrue(app.buttons["restartChat"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--live-chat-ui-test", "--preserve-ui-test-state"]
        app.launch()
        capture("interrupted-after-reopen")
        XCTAssertTrue(app.buttons["restartChat"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["chatNotice"].label.contains("上次请求未确认完成"))
        XCTAssertFalse(app.buttons["sendMessage"].isEnabled)
        XCTAssertFalse(app.staticTexts["assistantMessage"].exists)
        capture("interrupted-conversation")
        app.buttons["restartChat"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertTrue(input.isEnabled)
    }

    @MainActor
    func testRecoverableSessionCreatesWaitsAndResumesWithoutDuplicateModelCall() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--built-in-tools-ui-test"]
        app.launch()
        app.tabBars.buttons["实验室"].tap()
        let more = app.descendants(matching: .any).matching(identifier: "moreLabCapabilities").firstMatch
        reveal(more, in: app)
        more.tap()
        reveal(app.buttons["liveWorkflowLab"], in: app)
        app.buttons["liveWorkflowLab"].tap()

        let create = app.buttons["recoverableSessionCreate"]
        reveal(create, in: app)
        create.tap()
        let state = app.descendants(matching: .any).matching(identifier: "recoverableSessionState").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 10))
        reveal(state, in: app)
        XCTAssertEqual(state.label, "active")

        let wait = app.buttons["recoverableSessionWaitForUser"]
        reveal(wait, in: app)
        wait.tap()
        let waitingState = app.descendants(matching: .any).matching(identifier: "recoverableSessionState").firstMatch
        let waitingPredicate = NSPredicate(format: "label == %@", "waitingForUser")
        expectation(for: waitingPredicate, evaluatedWith: waitingState)
        waitForExpectations(timeout: 10)

        let send = app.buttons["recoverableSessionSend"]
        reveal(send, in: app)
        send.tap()
        let output = app.staticTexts["recoverableSessionOutput"]
        XCTAssertTrue(output.waitForExistence(timeout: 15))
        reveal(output, in: app)
        XCTAssertTrue(output.label.contains("可恢复 Session 第一轮"))
        capture("recoverable-session-resumed")
    }

    @MainActor
    func testSDKCapabilityLabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test"]
        app.launch()
        app.tabBars.buttons["实验室"].tap()
        let more = app.descendants(matching: .any).matching(identifier: "moreLabCapabilities").firstMatch
        reveal(more, in: app); more.tap()
        reveal(app.buttons["textResourceLab"], in: app)
        app.buttons["textResourceLab"].tap()
        app.buttons["textResourceMakePreview"].tap()
        XCTAssertTrue(app.buttons["textResourceReadNext"].waitForExistence(timeout: 10))
        app.buttons["textResourceReadNext"].tap()
        let offset = app.staticTexts["textResourceNextOffset"]
        reveal(offset, in: app)
        XCTAssertNotEqual(offset.label, "0")
        capture("text-resource-page")
        app.navigationBars["文本资源"].buttons.element(boundBy: 0).tap()
        reveal(app.buttons["structuredOutputLab"], in: app)
        app.buttons["structuredOutputLab"].tap()
        let source = app.descendants(matching: .any).matching(identifier: "structuredOutputSource").firstMatch
        source.tap()
        source.typeText("A small offline source for the schema test.")
        app.buttons["structuredOutputKeyboardDone"].tap()
        app.buttons["structuredOutputRun"].tap()
        let accepted = app.staticTexts["structuredOutputValidationOutcome"]
        XCTAssertTrue(accepted.waitForExistence(timeout: 10))
        reveal(accepted, in: app)
        XCTAssertEqual(accepted.label, "本地校验通过")
        capture("structured-validation")
        app.navigationBars["结构化输出"].buttons.element(boundBy: 0).tap()
        reveal(app.buttons["liveWorkflowLab"], in: app)
        app.buttons["liveWorkflowLab"].tap()
        let run = app.buttons["workflowRun"]
        reveal(run, in: app)
        run.tap()
        let state = app.descendants(matching: .any).matching(identifier: "workflowRunState").firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 15))
        let response = app.staticTexts["workflowFinalResponse"]
        reveal(response, in: app)
        XCTAssertTrue(response.label.contains("脚本验证完成"))
        capture("workflow-completed")
        app.navigationBars["真实模型 Workflow"].buttons.element(boundBy: 0).tap()
        reveal(app.buttons["localModelLab"], in: app)
        app.buttons["localModelLab"].tap()
        XCTAssertTrue(app.staticTexts["localModelsOfflineMode"].waitForExistence(timeout: 10))
        let empty = app.staticTexts["localModelsEmptyInventory"]
        reveal(empty, in: app)
        capture("local-models-environment")
        XCTAssertFalse(app.buttons["localModelsImportCatalog"].isEnabled)
    }

    @MainActor
    private func configureChat(in app: XCUIApplication, preservesConversation: Bool = false) {
        XCTAssertTrue(app.buttons["modelSettings"].waitForExistence(timeout: 10))
        app.buttons["modelSettings"].tap()
        app.buttons["sharedModelSettings"].tap()
        let key = app.secureTextFields["apiKeyField"]
        XCTAssertTrue(key.waitForExistence(timeout: 10))
        key.tap()
        key.typeText("ui-test-key")
        if preservesConversation {
            app.buttons["dismissSettingsKeyboard"].tap()
            let options = app.staticTexts["会话与图片（可选）"]
            reveal(options, in: app); options.tap()
            let persistence = app.switches["persistConversationToggle"]
            reveal(persistence, in: app)
            persistence.tap()
            expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: persistence)
            waitForExpectations(timeout: 5)
            capture("persistence-enabled-settings")
        }
        app.buttons["saveModelSettings"].tap()
        XCTAssertTrue(app.navigationBars["模型设置"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 10))
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY + 8 : app.frame.minY + 60
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY - 85 : app.frame.maxY - 90
            if element.exists {
                let rect = element.frame
                if rect.minY >= top && rect.maxY <= bottom && rect.height > 0 && element.isHittable { return }
                if rect.minY < top { app.swipeDown(velocity: .fast) } else { app.swipeUp(velocity: .fast) }
            } else { app.swipeUp(velocity: .fast) }
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    @MainActor
    private func capture(_ name: String) {
        let screenshot = XCUIApplication().screenshot()
        try? screenshot.pngRepresentation.write(to: FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-lab-\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
