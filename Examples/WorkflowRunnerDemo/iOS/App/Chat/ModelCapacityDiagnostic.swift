#if DEBUG
import Foundation

@MainActor
enum ModelCapacityDiagnostic {
    private enum Failure: Error { case check(Int) }
    static func run(workspace: LabWorkspaceModel) async {
        guard workspace.chat.isUITesting,
              ProcessInfo.processInfo.arguments.contains("--context-capacity-ui-test") else { return }
        do {
            var selected = DemoFileRecoveryFixture.settings
            selected.managesContext = true
            try workspace.store.save(selected, apiKey: DemoFileRecoveryFixture.key)
            let capacity = workspace.store.settings.modelCapacity
            try check(capacity.contextWindowTokens == 1_000_000 && capacity.maximumOutputTokens == 524_288, 1)
            try check(workspace.store.settings.maximumOutputTokens == 1_024, 2)
            workspace.taskText = "owned-next-draft"
            workspace.useRecommendedModelCapacity()
            try check(workspace.store.settings.maximumOutputTokens == 131_072 && workspace.store.settings.contextWindowTokens == 1_000_000, 3)
            try check(!workspace.store.settings.summarizesContext && workspace.taskText == "owned-next-draft", 4)
            let transport = LiveChatUITestTransport.contextCompression
            let before = await transport.audit()
            try check(before.mainRequests == 0 && before.summaryRequests == 0, 5)

            try workspace.store.save(DemoContextCompressionFixture.settings, apiKey: DemoFileRecoveryFixture.key)
            workspace.clearSelection(); workspace.selectResources()
            try check(await workspace.chat.importTextContent(name: "owned-four-pages.txt", text: DemoContextCompressionFixture.text), 6)
            workspace.taskText = DemoContextCompressionFixture.question
            workspace.performChatAction()
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while workspace.isApplying || workspace.chat.isBusy {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw Failure.check(90) }
                try await Task.sleep(for: .milliseconds(20))
            }
            try check(workspace.chat.messages.last?.text == DemoContextCompressionFixture.answer && workspace.chat.errorMessage == nil, 7)
            let audit = await transport.audit()
            try check(audit.mainRequests == 5 && audit.summaryRequests == 1, 8)
            try check(audit.mainOutputLimits == [128, 128, 128, 128, 128] && audit.summaryOutputLimit == 512, 9)
            try check(audit.finalRetainedPages == [2, 3] && audit.finalHasSummary && audit.finalHasQuestion, 10)
            try check(workspace.chat.contextCompactions.reduce(0) { $0 + $1.removedToolExchangeCount } == 2, 11)
            try check(workspace.chat.contextCompactions.contains { $0.usedModelSummary } && workspace.chat.contextFailure == nil, 12)
            try check(workspace.chat.statistics.summaryCallCount == 1, 13)
            print("MODEL_CAPACITY_DIAGNOSTIC_SUCCESS modelContext=1000000 modelOutput=524288 recommendation=131072 selectionCalls=0 mainCalls=5 summaryCalls=1 mainCap=128 summaryCap=512 removedExchanges=2 recentPairs=2 userPreserved=1 observedReceipt=1 realModelCalls=0")
        } catch let Failure.check(code) {
            print("MODEL_CAPACITY_DIAGNOSTIC_FAILURE code=\(code) realModelCalls=0")
        } catch {
            print("MODEL_CAPACITY_DIAGNOSTIC_FAILURE code=99 realModelCalls=0")
        }
    }
    private static func check(_ value: Bool, _ code: Int) throws {
        guard value else { throw Failure.check(code) }
    }
}
#endif
