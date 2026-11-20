import Foundation
import Testing
import BoneAgentKit
import BoneAgentTools
import BoneAgentTesting
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct BuiltInToolIntegrationTests {
    @Test func defaultsStayEmptyAndPresetsRespectMissingDependencies() throws {
        var settings = DemoLiveChatSettings()
        let empty = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil,
            handlers: .unavailable, searchAPIKey: "")
        #expect(empty.isEmpty)
        settings.applyToolPreset(.research, hasSearchKey: false)
        #expect(settings.enablesCalculator && settings.enablesDateTime && settings.enablesAskUser && settings.enablesTextResources)
        #expect(!settings.enablesWebFetch && !settings.enablesWebSearch)
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: DemoTextResourceStore(),
            handlers: .unavailable, searchAPIKey: "")
        #expect(Set(tools.map(\.definition.id)) == ["math.calculate", "time.query", "user.ask", "resource.list", "resource.search", "resource.readText"])
        #expect(try JSONDecoder().decode(DemoLiveChatSettings.self, from: JSONEncoder().encode(settings)) == settings)
    }

    @Test func realAgentWaitsForHostAnswerAndFeedsItBackToModel() async throws {
        var settings = DemoLiveChatSettings(); settings.enablesAskUser = true
        let question = try BoneUserQuestion(question: "你偏好什么？", kind: .text)
        let call = BoneInferenceToolCall(id: "ask-1", toolID: "user.ask", arguments: try JSONEncoder().encode(question))
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse(call), .finish(.init(text: "已使用回答"))])
        let probe = BuiltInProbe()
        let handlers = DemoToolInteractionHandlers(ask: { _ in
            await probe.mark(); return .init(text: "真实用户选择_3918")
        }, authorize: { _ in throw BoneAuthorizationError.denied })
        let effects = DemoToolEffectStore()
        let agent = try makeAgent(settings: settings, engine: engine, effects: effects, handlers: handlers)
        let result = try await agent.run(modelID: "offline", messages: [.init(role: .user, content: "请先问我")])
        #expect(result.steps == 2)
        #expect(await probe.calls == 1)
        let requests = await engine.receivedRequests()
        let resultMessage = try #require(requests.last?.messages.last?.toolResults?.results.first)
        let data = try #require(resultMessage.legacyResult)
        let answer = try JSONDecoder().decode(BoneUserAnswer.self, from: data)
        #expect(answer.text == "真实用户选择_3918" && answer.status == .answered)
    }

    @Test func deniedNetworkCallNeverTouchesInjectedTransport() async throws {
        var settings = DemoLiveChatSettings(); settings.enablesWebFetch = true; settings.webAllowedHosts = "example.com"
        let transport = BuiltInOfflineTransport()
        let call = BoneInferenceToolCall(id: "fetch-1", toolID: "web.fetch",
            arguments: try JSONEncoder().encode(BoneWebFetchInput(url: "https://example.com/article")))
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse(call)])
        let probe = BuiltInProbe()
        let handlers = DemoToolInteractionHandlers(ask: { _ in throw BoneAskUserError.unavailable },
            authorize: { _ in await probe.mark(); return false })
        let agent = try makeAgent(settings: settings, engine: engine, effects: DemoToolEffectStore(),
                                  handlers: handlers, transport: transport)
        do {
            _ = try await agent.run(modelID: "offline", messages: [.init(role: .user, content: "read")])
            Issue.record("Denied effect executed")
        } catch { #expect(error as? BoneAgentError == .toolExecutionFailed) }
        #expect(await transport.calls == 0)
        #expect(await probe.calls == 1)
    }

    @Test func grantIsBoundToOneCallAndCannotBeConsumedTwice() async throws {
        let effects = DemoToolEffectStore(clock: { 10 })
        let definition = BoneAskUserTool<BoneAgentEmptyContext>.definition
        let question = try BoneUserQuestion(question: "补充", kind: .text)
        let call = BoneInferenceToolCall(id: "q", toolID: definition.id, arguments: try JSONEncoder().encode(question))
        let context = try #require(await effects.context(for: call, definition: definition, handlers: .unavailable))
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: effects)
        let probe = BuiltInProbe()
        _ = try await pipeline.execute(arguments: call.arguments, definition: definition, context: context) {
            await probe.mark(); return Data("{}".utf8)
        }
        let snapshot = try #require(await effects.recoverySnapshot(effectID: context.effectID, currentLeaseGeneration: 1))
        #expect(snapshot.stepCommitted && snapshot.receipt?.outcome == .succeeded)
        await #expect(throws: BoneWorkflowToolExecutionError.authorizationRejected) {
            try await pipeline.execute(arguments: call.arguments, definition: definition, context: context) {
                await probe.mark(); return Data("{}".utf8)
            }
        }
        #expect(await probe.calls == 1)
    }

    @Test func policyWithoutEffectPipelineStillCannotInvokeUserInteraction() async throws {
        var settings = DemoLiveChatSettings(); settings.enablesAskUser = true
        let question = try BoneUserQuestion(question: "补充", kind: .text)
        let call = BoneInferenceToolCall(id: "q", toolID: "user.ask", arguments: try JSONEncoder().encode(question))
        let engine = BoneScriptedInferenceEngine(script: [try toolResponse(call)])
        let probe = BuiltInProbe()
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil,
            handlers: .init(ask: { _ in await probe.mark(); return .init(text: "answer") }, authorize: { _ in false }), searchAPIKey: "")
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: tools), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 2, toolImpactPolicy: DemoBuiltInToolAssembly.impactPolicy(settings: settings)))
        do {
            _ = try await agent.run(modelID: "offline", messages: [.init(role: .user, content: "ask")])
            Issue.record("A missing pipeline was accepted")
        } catch { #expect(error as? BoneAgentError == .toolExecutionFailed) }
        #expect(await probe.calls == 0)
    }

    private func toolResponse(_ call: BoneInferenceToolCall) throws -> BoneInferenceResponse {
        .assistantTurn(turn: try .init(content: [.toolCall(call)]), finishReason: .toolCalls,
                       usage: nil, refusal: nil, providerContinuation: nil)
    }
    private func makeAgent(settings: DemoLiveChatSettings, engine: BoneScriptedInferenceEngine,
                           effects: DemoToolEffectStore, handlers: DemoToolInteractionHandlers,
                           transport: (any BoneWebHTTPTransport)? = nil) throws -> BoneAgent {
        let tools = try DemoBuiltInToolAssembly.make(settings: settings, resources: nil, handlers: handlers,
            searchAPIKey: "", webTransport: transport)
        let webPolicy = settings.enablesWebFetch ? try BoneWebHostPolicy(allowedHosts: settings.webHostNames) : nil
        return BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: tools), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 2, toolImpactPolicy: DemoBuiltInToolAssembly.impactPolicy(settings: settings),
                toolExecutionPipeline: .init(effectStore: effects), toolExecutionContextProvider: { call, definition in
                    try await effects.context(for: call, definition: definition, handlers: handlers, webPolicy: webPolicy,
                                              searchConfiguration: settings.search)
                }))
    }
}

private actor BuiltInProbe {
    private(set) var calls = 0
    func mark() { calls += 1 }
}
private actor BuiltInOfflineTransport: BoneWebHTTPTransport {
    private(set) var calls = 0
    func send(request: URLRequest, maximumResponseBytes: Int) throws -> BoneWebHTTPResponse {
        calls += 1
        throw BoneWebError.requestFailed
    }
}

extension BuiltInToolIntegrationTests {
    @Test func resourcePresetRegistersUnifiedFileResourceTools() async throws {
        var settings = DemoLiveChatSettings()
        settings.enablesTextResources = true
        settings.enablesCalculator = true
        settings.enablesDateTime = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("demo-file-tools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileResources = DemoFileResourceStore(directory: root)
        let fileAccess = DemoFileResourceAccess()
        let tools = try DemoBuiltInToolAssembly.make(settings: settings,
            resources: DemoTextResourceStore(), fileResources: fileResources,
            fileResourceAccess: fileAccess, handlers: .unavailable, searchAPIKey: "")
        #expect(Set(tools.map(\.definition.id)) == [
            "math.calculate", "time.query", "resource.list", "resource.search", "resource.readText",
            "resource.inspect", "resource.detectFormat", "resource.readWindow", "resource.readOffice",
            "resource.listEntries", "resource.readBytes", "resource.readPDFLayout", "resource.ocr"
        ])
    }
}
