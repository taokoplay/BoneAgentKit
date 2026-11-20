import Foundation
import Testing
import BoneAgentTools
@testable import WorkflowRunnerDemo

struct SearchEntryRecoveryTests {
    @Test func selectingSearchToolPreparesKeylessBaiduOnlyWhenNoServiceWasConfigured() throws {
        let initial = DemoSearchConfiguration()
        let prepared = initial.preparedForAutomaticToolSelection()
        #expect(!initial.baiduWebEnabled && initial.automaticChannel == .brave)
        #expect(prepared.automaticEnabled && prepared.automaticChannel == .baiduWeb)
        #expect(!prepared.braveEnabled && !prepared.deepSeekEnabled)
        #expect(prepared.preferredChannel == initial.preferredChannel && prepared.browserEngine == initial.browserEngine)
        #expect(prepared.preparedForAutomaticToolSelection() == prepared)
        var settings = DemoLiveChatSettings(); settings.search = prepared
        let plan = DemoLabToolPlan(groups: [.webSearch])
        #expect(plan.requirements(settings: settings, hasModelKey: true, hasSearchKey: false,
                                  hasDeepSeekSearchKey: false).isEmpty)
    }

    @Test(arguments: [DemoSearchChannel.brave, .deepSeek, .baiduWeb])
    func explicitServiceSelectionIsPreservedEvenWhenDisabled(channel: DemoSearchChannel) {
        var config = DemoSearchConfiguration()
        config.isEnabled = false; config.automaticChannel = channel
        config.braveEnabled = channel == .brave
        config.deepSeekEnabled = channel == .deepSeek
        config.baiduWebEnabled = channel == .baiduWeb
        #expect(config.preparedForAutomaticToolSelection() == config)
    }

    @Test func explicitBaiduActionPreservesOtherServiceAndManualBrowserPreferences() {
        var config = DemoSearchConfiguration()
        config.isEnabled = false; config.braveEnabled = true; config.deepSeekEnabled = true
        config.automaticChannel = .deepSeek; config.keepsBrowserSession = true
        config.preferredChannel = .browser; config.browserEngine = .bing
        let selected = config.selectingBaiduWebForTask()
        #expect(selected.isEnabled && selected.baiduWebEnabled && selected.automaticChannel == .baiduWeb)
        #expect(selected.braveEnabled && selected.deepSeekEnabled)
        #expect(selected.preferredChannel == .browser && selected.browserEngine == .bing && selected.keepsBrowserSession)
    }

    @Test func failedQuestionCanBeRetriedWithoutSendingOrReplacingNextDraft() throws {
        let retry = try #require(DemoTaskRecovery.preparingRetry(original: "今天深圳天气", draft: "下一条问题", retained: nil))
        #expect(retry.task == "今天深圳天气" && retry.retained == "下一条问题")
        let swapped = try #require(DemoTaskRecovery.preparingRetry(original: "原问题", draft: "下一条", retained: "原问题"))
        #expect(swapped.task == "原问题" && swapped.retained == "下一条")
        #expect(DemoTaskRecovery.preparingRetry(original: "原问题", draft: "原问题", retained: "保留任务") == .init(task: "原问题", retained: "保留任务"))
        #expect(DemoTaskRecovery.preparingRetry(original: "原问题", draft: "  ", retained: "保留任务") == .init(task: "原问题", retained: "保留任务"))
    }

    @Test func retryRefusesToOverwriteTwoIndependentDraftsOrAnEmptyQuestion() {
        #expect(DemoTaskRecovery.preparingRetry(original: "原问题", draft: "下一条", retained: "其他任务") == nil)
        #expect(DemoTaskRecovery.preparingRetry(original: " \n ", draft: "下一条", retained: nil) == nil)
    }
}
