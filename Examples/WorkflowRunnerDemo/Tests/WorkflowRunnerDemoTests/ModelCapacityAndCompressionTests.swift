import Foundation
import Testing
import BoneAgentKit
import BoneAgentTesting
@testable import WorkflowRunnerDemo

struct ModelCapacityAndCompressionTests {
    @Test func officialCapacityRequiresExactModelProviderAndEndpoint() throws {
        var settings = DemoFileRecoveryFixture.settings
        let capacity = settings.modelCapacity
        #expect(capacity.contextWindowTokens == 1_000_000)
        #expect(capacity.maximumOutputTokens == 524_288 && capacity.recommendedOutputTokens == 131_072)
        #expect(capacity.outputIncludesThinking && capacity.sourceTitle == "MiniMax 官方文档")
        #expect(settings.maximumOutputTokens == 1_024 && settings.contextWindowTokens == 32_768)
        settings.modelID = "MiniMax-M3.1-Flash-alias"
        #expect(settings.modelCapacity == .unknown)
        settings.modelID = "MiniMax-M3.1-Flash"
        settings.baseURL = "https://example.com/anthropic"
        #expect(settings.modelCapacity == .unknown)
        settings.baseURL = "https://api.minimaxi.com/other"
        #expect(settings.modelCapacity == .unknown)
        settings.selectProvider(.customOpenAI)
        settings.baseURL = "https://api.minimaxi.com/anthropic"; settings.modelID = "MiniMax-M3.1-Flash"
        #expect(settings.modelCapacity == .unknown)
    }

    @Test func selectedOutputAndWindowAreValidatedIndependentlyOfModelMaximum() throws {
        var settings = DemoFileRecoveryFixture.settings
        settings.managesContext = true
        settings.maximumOutputTokens = 131_072
        #expect(throws: DemoChatConfigurationError.invalidContextWindow) { try settings.validated() }
        settings.useRecommendedModelCapacity()
        let valid = try settings.validated()
        #expect(valid.maximumOutputTokens == 131_072 && valid.contextWindowTokens == 1_000_000)
        #expect(valid.availableInputTokens == 848_800)
        #expect(valid.replyLimitChoices.contains(524_288) && valid.replyLimitChoices.contains(16_384))
        #expect(!valid.summarizesContext && !valid.compactsCurrentToolHistory)
        settings.maximumOutputTokens = 524_288
        _ = try settings.validated()
        settings.maximumOutputTokens = 524_289
        #expect(throws: DemoChatConfigurationError.invalidOutputLimit) { try settings.validated() }
        settings.maximumOutputTokens = DemoModelCapacity.maximumConfigurableOutputTokens + 1
        #expect(throws: DemoChatConfigurationError.invalidOutputLimit) { try settings.validated() }
        var unknown = DemoContextCompressionFixture.settings
        unknown.maximumOutputTokens = 65_536; unknown.contextWindowTokens = 131_072
        #expect(try unknown.validated().maximumOutputTokens == 65_536)
        #expect(unknown.modelCapacity.maximumOutputTokens == nil)
    }

    @Test func legacyPreferencesAndBudgetsStayUnchangedUntilExplicitSelection() throws {
        let source = Data(#"{"provider":"MiniMax","baseURL":"https://api.minimaxi.com/anthropic","modelID":"MiniMax-M3.1-Flash","maximumOutputTokens":1024,"managesContext":true,"summarizesContext":false,"contextWindowTokens":32768}"#.utf8)
        var settings = try JSONDecoder().decode(DemoLiveChatSettings.self, from: source)
        #expect(settings.contextToolHistoryCompaction == nil && settings.contextSummaryOutputTokens == nil)
        #expect(settings.summaryOutputTokens == 512 && settings.runInputByteLimit == 512 * 1_024)
        #expect(settings.runOutputByteLimit == 256 * 1_024 && settings.streamByteLimit == 256 * 1_024)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        #expect(object["contextToolHistoryCompaction"] == nil && object["contextSummaryOutputTokens"] == nil)
        settings.setModelSummaryEnabled(true)
        #expect(settings.summaryOutputTokens == 8_192 && settings.maximumOutputTokens == 1_024)
        #expect(!settings.compactsCurrentToolHistory)
        settings.contextToolHistoryCompaction = true
        #expect(settings.compactsCurrentToolHistory)
        settings.setModelSummaryEnabled(false)
        #expect(!settings.compactsCurrentToolHistory)
        settings.useRecommendedModelCapacity()
        #expect(settings.runInputByteLimit == 4_000_000)
        #expect(settings.runOutputByteLimit >= 131_072 * 8)
        #expect(settings.streamByteLimit >= 131_072 * 32)
    }

    @Test func currentTurnCompactionRequiresBothExplicitOptionsAndUsesIndependentSummaryBudget() throws {
        var settings = DemoContextCompressionFixture.settings
        let engine = BoneScriptedInferenceEngine(script: [.finish(.init(text: "owned"))])
        let enabled = try #require(try DemoLiveChatSession.contextManagement(settings: settings, engine: engine))
        #expect(enabled.minimumRecentToolExchangeCount == 2 && enabled.maximumSummaryOutputTokens == 512)
        #expect(enabled.preferredOutputTokens == 512 && enabled.maximumSummaryCallsPerRun == 1)
        settings.contextToolHistoryCompaction = false
        #expect(try DemoLiveChatSession.contextManagement(settings: settings, engine: engine)?.minimumRecentToolExchangeCount == nil)
        settings.contextToolHistoryCompaction = true; settings.summarizesContext = false
        let trimming = try #require(try DemoLiveChatSession.contextManagement(settings: settings, engine: engine))
        #expect(trimming.minimumRecentToolExchangeCount == nil && trimming.summarizer == nil)
        settings.managesContext = false
        #expect(try DemoLiveChatSession.contextManagement(settings: settings, engine: engine) == nil)
    }

    @Test(arguments: [false, true])
    func singleLongTaskCompactsOnlyWhenEnabledAndReportsRealOutcome(enabled: Bool) async throws {
        var settings = DemoContextCompressionFixture.settings
        settings.contextToolHistoryCompaction = enabled
        let store = DemoTextResourceStore()
        let resource = try await store.add(name: "owned-four-pages.txt", text: DemoContextCompressionFixture.text)
        let transport = DemoContextCompressionTransport()
        let updates = CompressionUpdates()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: "owned-offline-key",
            transport: transport, observer: { await updates.receive($0) }, textResources: store)
        if enabled {
            let reply = try await session.send(DemoContextCompressionFixture.question, resources: [resource])
            #expect(reply.text == DemoContextCompressionFixture.answer && reply.steps == 5 && reply.toolCalls == 4)
            let audit = await transport.audit()
            #expect(audit.mainRequests == 5 && audit.summaryRequests == 1)
            #expect(audit.mainOutputLimits == [128, 128, 128, 128, 128] && audit.summaryOutputLimit == 512)
            #expect(audit.finalRetainedPages == [2, 3] && audit.finalHasSummary && audit.finalHasQuestion)
            let receipts = await updates.receipts
            #expect(receipts.reduce(0) { $0 + $1.removedToolExchangeCount } == 2)
            #expect(receipts.contains { $0.usedModelSummary && $0.estimatedRequestTokenReduction > 0 })
            #expect(await updates.failure == nil)
            #expect(await session.statistics().summaryCallCount == 1)
        } else {
            await #expect(throws: DemoLiveChatFailure.limitReached) {
                try await session.send(DemoContextCompressionFixture.question, resources: [resource])
            }
            #expect(await session.failureDiagnostic()?.code == .contextManagement)
            let receipts = await updates.receipts
            let failure = await updates.failure
            #expect(receipts.isEmpty && failure == .inputExceedsBudget)
            #expect(await transport.audit().summaryRequests == 0)
        }
    }

    @Test func largeExplicitOutputLimitReachesEveryActualMiniMaxRequest() async throws {
        var settings = DemoFileRecoveryFixture.settings
        settings.managesContext = true
        settings.useRecommendedModelCapacity()
        let store = DemoTextResourceStore()
        let resource = try await store.add(name: "owned-22000.txt", text: DemoFileRecoveryFixture.text)
        let transport = DemoFileRecoveryTransport()
        let session = try await DemoLiveChatSession.make(settings: settings, apiKey: DemoFileRecoveryFixture.key,
            transport: transport, textResources: store)
        let reply = try await session.send(DemoFileRecoveryFixture.question, resources: [resource])
        #expect(reply.text == DemoFileRecoveryFixture.answer && reply.toolCalls == 2)
        #expect(await transport.audit().replyLimits == [131_072, 131_072, 131_072])
    }

    @Test func largeReplyBudgetIsValidInSafeFailureLogs() async throws {
        let record = DemoRunFailureDiagnostic(error: BoneInferenceTransportError.outputTruncated, failure: .limitReached,
            inferenceDiagnostic: .outputTruncated, inferenceResponses: 0, toolPreparations: 0, completedTools: 0,
            networkConfirmations: 0, maximumReplyTokens: 131_072, tool: nil)
        #expect(record.isValid)
        #expect(try JSONDecoder().decode(DemoRunFailureDiagnostic.self, from: JSONEncoder().encode(record)) == record)
    }
}

private actor CompressionUpdates {
    private(set) var receipts: [BoneContextCompactionReceipt] = []
    private(set) var failure: BoneContextFailureDiagnostic?
    func receive(_ update: DemoLiveChatUpdate) {
        switch update {
        case .contextCompacted(let receipt): receipts.append(receipt)
        case .contextFailure(let value): failure = value
        default: break
        }
    }
}
