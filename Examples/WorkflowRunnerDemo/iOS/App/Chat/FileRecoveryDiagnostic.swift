#if DEBUG
import Foundation
import BoneAgentKit

/// Explicitly launched offline diagnostics; normal app startup never runs this path.
@MainActor
enum FileRecoveryDiagnostic {
    private enum Failure: Error { case check(Int) }

    static func run(workspace: LabWorkspaceModel, completeFlow: Bool) async {
        guard workspace.chat.isUITesting,
              ProcessInfo.processInfo.arguments.contains("--file-recovery-ui-test") else { return }
        if ProcessInfo.processInfo.arguments.contains("--disk-resource-ui-test") {
            await runDiskResources(workspace)
            return
        }
        do {
            let original = try await prepareFailedTask(workspace)
            let transport = LiveChatUITestTransport.fileRecovery
            let beforePreview = await transport.audit().requests
            let first = try await workspace.chat.readLocalTextPage(original, offset: 0)
            let next = try await workspace.chat.readLocalTextPage(original, offset: try required(first.nextOffset, code: 10))
            try check(first.offset == 0 && next.nextOffset == nil && first.text.utf8.count <= 16_384, 11)
            try check(Data((first.text + next.text).utf8) == Data(DemoFileRecoveryFixture.text.utf8), 12)
            try check(await transport.audit().requests == beforePreview, 13)

            try check(await workspace.chat.importTextContent(name: "future-draft.txt", text: DemoFileRecoveryFixture.futureText), 14)
            let future = try required(workspace.chat.pendingResources.first, code: 15)
            await transport.forbid(future.id)
            workspace.taskText = DemoFileRecoveryFixture.nextQuestion
            if !completeFlow {
                print("FILE_RECOVERY_UI_READY bytes=22000 requests=4 localPreviewCalls=0")
                return
            }
            workspace.setReplyLimit(4_096)
            try check(workspace.store.settings.maximumOutputTokens == 4_096, 16)
            try check(await transport.audit().requests == beforePreview, 17)
            workspace.retryFailedTask()
            try check(workspace.confirmsNewRun, 18)
            try check(await transport.audit().requests == beforePreview, 19)
            workspace.confirmNewRun()
            try await waitUntilIdle(workspace)
            try check(workspace.chat.errorMessage == nil && !workspace.chat.needsNewConversation, 20)
            try check(workspace.chat.messages.last?.text == DemoFileRecoveryFixture.answer, 21)
            try check(workspace.chat.messages.first?.resourceIDs == [original.id], 22)
            try check(workspace.taskText == DemoFileRecoveryFixture.nextQuestion && workspace.chat.pendingResourceIDs == [future.id], 23)
            try check(workspace.chat.failedTask == nil && workspace.chat.unfinishedReply == nil, 24)
            try check(workspace.chat.resources.contains(original) && workspace.chat.resources.contains(future), 25)
            let audit = await transport.audit()
            try check(audit.requests == 7 && audit.nonStreamingCalls == 0, 26)
            try check(audit.replyLimits == [1_024, 1_024, 1_024, 1_024, 4_096, 4_096, 4_096], 27)
            try check(audit.previewReferences == [original.preview.reference] && audit.pageReferences == [original.preview.reference], 28)
            try check(!audit.sawForbiddenMaterial, 29)
            try await verifyRetainedTaskSwap()
            print("FILE_RECOVERY_DIAGNOSTIC_SUCCESS bytes=22000 primaryRequests=7 tools=4 priorTurnFile=1 localPreviewCalls=0 capChoiceCalls=0 sameReference=1 futureDraftPreserved=1 futureFileSent=0 partialCommitted=0 dualFailurePreserved=1 realModelCalls=0")
        } catch let Failure.check(code) {
            print("FILE_RECOVERY_DIAGNOSTIC_FAILURE code=\(code) realModelCalls=0")
        } catch {
            print("FILE_RECOVERY_DIAGNOSTIC_FAILURE code=99 realModelCalls=0")
        }
    }

    /// 仅隔离 UI 测试调用：验证真实导入、设置切换和旧存档保留，不发送模型请求。
    private static func runDiskResources(_ workspace: LabWorkspaceModel) async {
        // 自建文件比旧上限多一个字节，不访问用户选择文件。
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("disk-resource-fixture.txt")
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentLabConversationsUITests")
        let archive = root.appendingPathComponent("conversation-private-v1.json")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: archive) }
        // 固定阶段码用于定位失败，不输出凭据或私有数据。
        var stage = 60
        do {
            try Data(repeating: 0x61, count: DemoTextResourceStore.maximumResourceBytes + 1).write(to: url)
            // 哨兵只证明被拒操作不改存档；主动关闭保存和重置仍须清理。
            let sentinel = Data("isolated-existing-archive".utf8)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try sentinel.write(to: archive)
            var settings = DemoFileRecoveryFixture.settings
            settings.preservesConversation = true
            stage = 70
            try workspace.store.save(settings, apiKey: DemoFileRecoveryFixture.key)
            stage = 71
            await workspace.chat.importText(url: url, settings: settings)
            try check(workspace.chat.resources.isEmpty && workspace.chat.errorMessage?.contains("关闭") == true, 61)
            try check(try Data(contentsOf: archive) == sentinel, 62)
            settings.preservesConversation = false
            // 与用户关闭开关走同一保存回调；不在诊断里直接删除存档。
            workspace.openConfiguration(.model)
            try workspace.store.save(settings, apiKey: DemoFileRecoveryFixture.key)
            workspace.configurationSaved()
            try await waitUntilIdle(workspace)
            try check(!FileManager.default.fileExists(atPath: archive.path), 72)
            await workspace.chat.importText(url: url, settings: settings)
            let imported = try required(workspace.chat.pendingResources.first, code: 63)
            try check(imported.isDiskBacked && workspace.chat.errorMessage == nil, 64)
            // 导入后开启保存必须在任何凭据/偏好写入之前失败，原设置和附件保留。
            try sentinel.write(to: archive)
            settings.preservesConversation = true
            do {
                try workspace.store.save(settings, apiKey: DemoFileRecoveryFixture.key)
                throw Failure.check(65)
            } catch DemoTextResourceStoreError.largeResourceCannotBeSaved { }
            try check(!workspace.store.settings.preservesConversation && workspace.chat.pendingResources == [imported], 66)
            try check(try Data(contentsOf: archive) == sentinel, 73)
            try check(await workspace.chat.resetForRun(preservingPendingAttachments: true), 67)
            try check(!FileManager.default.fileExists(atPath: archive.path) && workspace.chat.pendingResources == [imported], 68)
            let page = try await workspace.chat.readLocalTextPage(imported, offset: 524_288)
            try check(page.text == "a" && page.nextOffset == nil, 69)
            workspace.taskText = "DISK_RESOURCE_DIAGNOSTIC_SUCCESS"
            print("DISK_RESOURCE_DIAGNOSTIC_SUCCESS settingsBlocked=1 rejectedOperationsPreserveArchive=1 explicitCleanup=1 pendingPreserved=1 realModelCalls=0")
        } catch let Failure.check(code) {
            workspace.taskText = "DISK_RESOURCE_DIAGNOSTIC_FAILURE_\(code)"
            print("DISK_RESOURCE_DIAGNOSTIC_FAILURE code=\(code) realModelCalls=0")
        } catch let error as LiveChatKeychainError {
            // 仅暴露系统状态码，区分测试签名/权限问题和附件断言失败。
            workspace.taskText = "DISK_RESOURCE_DIAGNOSTIC_FAILURE_KEYCHAIN_\(error.status)"
        } catch {
            workspace.taskText = "DISK_RESOURCE_DIAGNOSTIC_FAILURE_STAGE_\(stage)"
            print("DISK_RESOURCE_DIAGNOSTIC_FAILURE stage=\(stage) realModelCalls=0")
        }
    }

    private static func prepareFailedTask(_ workspace: LabWorkspaceModel) async throws -> DemoImportedTextResource {
        try workspace.store.save(DemoFileRecoveryFixture.settings, apiKey: DemoFileRecoveryFixture.key)
        workspace.clearSelection()
        workspace.selectResources()
        try check(await workspace.chat.importTextContent(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text), 1)
        let original = try required(workspace.chat.pendingResources.first, code: 2)
        workspace.taskText = DemoFileRecoveryFixture.initialQuestion
        workspace.performChatAction()
        try await waitUntilIdle(workspace)
        try check(workspace.chat.messages.count == 2 && workspace.chat.pendingResourceIDs.isEmpty, 3)
        try check(workspace.chat.messages.first?.resourceIDs == [original.id] && workspace.chat.errorMessage == nil, 4)
        workspace.taskText = DemoFileRecoveryFixture.question
        workspace.performChatAction()
        try await waitUntilIdle(workspace)
        try check(workspace.chat.failureDiagnostic?.code == .outputTruncated && workspace.chat.needsNewConversation, 5)
        try check(workspace.chat.failedTask?.materials.resourceIDs == [original.id], 6)
        try check(workspace.chat.failedTask?.text == DemoFileRecoveryFixture.question, 7)
        try check(workspace.chat.unfinishedReply == DemoFileRecoveryFixture.partial, 8)
        try check(workspace.chat.messages.count == 3 && !workspace.chat.messages.contains { $0.text == DemoFileRecoveryFixture.partial }, 9)
        return original
    }
    private static func verifyRetainedTaskSwap() async throws {
        let store = LiveChatSettingsStore(isUITesting: true)
        let chat = LiveChatModel(isUITesting: true)
        let workspace = LabWorkspaceModel(store: store, chat: chat)
        await chat.prepare(store: store)
        let first = try await prepareFailedTask(workspace)
        let taskA = try required(chat.failedTask, code: 30)
        try check(await chat.importTextContent(name: "second-owned.txt", text: DemoFileRecoveryFixture.text), 31)
        let second = try required(chat.pendingResources.first, code: 32)
        workspace.taskText = DemoFileRecoveryFixture.question + "，第二个任务"
        workspace.performChatAction()
        try check(workspace.confirmsNewRun && workspace.retainedTask?.id == taskA.id, 33)
        workspace.confirmNewRun()
        try await waitUntilIdle(workspace)
        let taskB = try required(chat.failedTask, code: 34)
        try check(taskB.materials.resourceIDs == [second.id] && taskB.id != taskA.id, 35)
        workspace.taskText = DemoFileRecoveryFixture.nextQuestion
        workspace.setReplyLimit(4_096)
        workspace.retryRetainedTask()
        try check(workspace.confirmsNewRun, 36)
        workspace.confirmNewRun()
        try await waitUntilIdle(workspace)
        try check(chat.messages.last?.text == DemoFileRecoveryFixture.answer && chat.errorMessage == nil, 37)
        try check(chat.messages.first?.resourceIDs == [first.id], 38)
        try check(workspace.retainedTask == taskB && chat.resources.contains(second), 39)
        try check(workspace.taskText == DemoFileRecoveryFixture.nextQuestion, 40)
    }

    private static func waitUntilIdle(_ workspace: LabWorkspaceModel) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while workspace.isApplying || workspace.chat.isBusy {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Failure.check(90) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    private static func check(_ value: Bool, _ code: Int) throws {
        guard value else { throw Failure.check(code) }
    }
    private static func required<Value>(_ value: Value?, code: Int) throws -> Value {
        guard let value else { throw Failure.check(code) }
        return value
    }
}
#endif
