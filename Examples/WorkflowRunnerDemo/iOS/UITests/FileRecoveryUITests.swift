import XCTest

final class FileRecoveryUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 120 }

    /// 使用自建大附件验证保存设置切换与存档保护，无真实模型或用户文件访问。
    @MainActor
    func testDiskResourceImportBlocksPersistenceAndPreservesArchive() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--file-recovery-ui-test",
                               "--run-file-recovery-diagnostic", "--disk-resource-ui-test"]
        app.launch()
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        // 同时等待成功和失败诊断，避免真正失败被固定超时掩盖。
        let finished = NSPredicate(format: "value BEGINSWITH %@ OR value BEGINSWITH %@",
                                   "DISK_RESOURCE_DIAGNOSTIC_SUCCESS",
                                   "DISK_RESOURCE_DIAGNOSTIC_FAILURE")
        expectation(for: finished, evaluatedWith: input)
        waitForExpectations(timeout: 30)
        XCTAssertEqual(input.value as? String, "DISK_RESOURCE_DIAGNOSTIC_SUCCESS")
        XCTAssertTrue(app.buttons["预览 disk-resource-fixture.txt"].exists)
    }

    @MainActor
    func testLocalPreviewAndExplicitBudgetRetryPreserveNextDraft() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--live-chat-ui-test", "--file-recovery-ui-test", "--seed-file-recovery-ui-state"]
        app.launch()
        let retry = app.buttons["retryFailedTask"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25))
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "previewRetainedResource_")).firstMatch
        reveal(original, app: app, upward: false)
        original.tap()
        let next = app.buttons["nextTextResourcePreviewPage"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.isEnabled)
        XCTAssertFalse(app.buttons["previousTextResourcePreviewPage"].isEnabled)
        next.tap()
        XCTAssertTrue(app.staticTexts["第 2 页 · 已到末尾"].waitForExistence(timeout: 10))
        XCTAssertFalse(next.isEnabled)
        app.buttons["previousTextResourcePreviewPage"].tap()
        XCTAssertTrue(app.staticTexts["第 1 页"].waitForExistence(timeout: 10))
        app.buttons["dismissTextResourcePreview"].tap()
        let budget = app.buttons["truncationReplyBudget"]
        reveal(budget, app: app)
        budget.tap()
        app.buttons["replyLimit_4096"].tap()
        XCTAssertTrue(budget.label.contains("4096"))
        // Merely choosing the cap leaves the failed task and its retry action intact.
        XCTAssertTrue(retry.exists)
        reveal(retry, app: app, upward: false)
        retry.tap()
        XCTAssertTrue(app.buttons["confirmNewToolRun"].waitForExistence(timeout: 10))
        app.buttons["confirmNewToolRun"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "文件内容概览已完成")).firstMatch.waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any).matching(identifier: "chatInput").firstMatch
        XCTAssertEqual(input.value as? String, "下一条独立草稿")
        XCTAssertTrue(app.buttons["预览 future-draft.txt"].exists)
        XCTAssertFalse(app.staticTexts["chatError"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "file-recovery-owned-fixture"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<10 {
            if element.isHittable { return }
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.isHittable)
    }
}
