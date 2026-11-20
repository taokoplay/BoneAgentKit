import Foundation
import Testing
import BoneAgentKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WorkflowRunnerDemo

struct LiveChatCapabilitiesTests: Sendable {
    @Test(.timeLimit(.minutes(1)))
    func realProviderDeltasArriveBeforeCompletionAndHistoryUsesSDKTurns() async throws {
        let channel = BoneInferenceRawEventStream.makeStream()
        let stub = CapabilityHTTPStub([
            .stream(channel.stream), .events(try CapabilityFixtures.textEvents(["第二", "轮"]))
        ])
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: CapabilityFixtures.settings(), apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }
        )
        #expect(await stub.requests.isEmpty)
        let pending = Task { try await session.send("第一轮问题") }
        defer { pending.cancel(); channel.continuation.finish() }
        channel.continuation.yield(try CapabilityFixtures.delta(["reasoning_content": "PRIVATE REASONING"]))
        channel.continuation.yield(try CapabilityFixtures.delta(["content": "第一"]))
        await updates.waitForTextCount(1)
        #expect(await updates.deltas == ["第一"])
        #expect(await updates.terminalCount == 0)
        #expect(await updates.phases.contains(.reasoning))
        channel.continuation.yield(try CapabilityFixtures.delta(["content": "轮"]))
        for event in try CapabilityFixtures.ending() { channel.continuation.yield(event) }
        channel.continuation.finish()
        let first = try await pending.value
        let second = try await session.send("第二轮问题")
        #expect(first.text == "第一轮")
        #expect(second.text == "第二轮")
        #expect(await updates.drafts == [["第一", "轮"], ["第二", "轮"]])
        let requests = await stub.requests
        try #require(requests.count == 2)
        for request in requests {
            #expect(try CapabilityFixtures.body(request)["stream"] as? Bool == true)
        }
        let history = try CapabilityFixtures.messages(requests[1])
        #expect(history.compactMap { $0["role"] as? String } == ["user", "assistant", "user"])
        #expect(history.compactMap { $0["content"] as? String } == ["第一轮问题", "第一轮", "第二轮问题"])
        let statistics = await session.statistics()
        #expect(statistics.roundCount == 2)
        #expect(statistics.successfulRoundCount == 2)
        #expect(statistics.stepCount == 2)
        #expect(statistics.tokens.knownUsage?.inputTokens == 6)
        #expect(statistics.tokens.knownUsage?.outputTokens == 4)
        #expect(statistics.timeToFirstTokenSampleCount == 0)
        #expect(statistics.averageTimeToFirstTokenSeconds == nil)
        #expect(statistics.outputTokensPerSecond == nil)
        #expect(await stub.nonStreamingCalls == 0)
    }

    @Test
    func adapterReturnsExactCompletedResponseAndHidesReasoningAndToolFragments() async throws {
        let continuation = try BoneInferenceProviderContinuation(provider: .custom, data: Data("opaque".utf8))
        let call = BoneInferenceToolCall(id: "call-1", toolID: "test-tool", arguments: Data("{}".utf8))
        let response = BoneInferenceResponse.assistantTurn(
            turn: try .init(content: [.text("canonical answer"), .toolCall(call)]), finishReason: .toolCalls,
            usage: .init(inputTokens: 10, outputTokens: 7, cachedInputTokens: nil, reasoningTokens: nil),
            refusal: nil, providerContinuation: continuation
        )
        let detailed = BoneInferenceDetailedResult(
            response: response, reasoning: try .init(kind: .providerReadable, text: "PRIVATE REASONING")
        )
        let updates = CapabilityUpdates()
        let engine = DemoObservedInferenceEngine(engine: CapabilityEventEngine(events: [
            .reasoningStarted(kind: .providerReadable), .reasoningDelta("PRIVATE REASONING"),
            .reasoningCompleted, .textDelta("public fragment"),
            .toolCallStarted(id: "call-1", toolID: "test-tool"),
            .toolArgumentsDelta(id: "call-1", data: Data("PRIVATE ARGUMENTS".utf8)),
            .toolCallCompleted(id: "call-1"), .completed(detailed)
        ]), observer: { await updates.receive($0) })
        let result = try await engine.inferUsingStream(request: CapabilityFixtures.request(), options: .init())
        #expect(result == response)
        #expect(await updates.deltas == ["public fragment"])
        #expect(await updates.drafts.count == 1)
    }

    @Test(arguments: [0, 1, 2])
    func adapterRequiresExactlyOneCompletionAndNoLateEvents(kind: Int) async throws {
        let completed = BoneInferenceStreamEvent.completed(.init(response: .init(text: "complete"), reasoning: nil))
        let tail: [BoneInferenceStreamEvent]
        switch kind {
        case 0: tail = []
        case 1: tail = [completed, completed]
        default: tail = [completed, .textDelta("late")]
        }
        let updates = CapabilityUpdates()
        let engine = DemoObservedInferenceEngine(
            engine: CapabilityEventEngine(events: [.textDelta("partial")] + tail),
            observer: { await updates.receive($0) }
        )
        do {
            _ = try await engine.inferUsingStream(request: CapabilityFixtures.request(), options: .init())
            Issue.record("An incomplete or malformed stream was accepted")
        } catch {
            #expect(error as? BoneInferenceTransportError == .invalidResponse)
        }
        #expect(await updates.deltas == ["partial"])
    }

    @Test
    func unsupportedStreamingNeverFallsBackAndOptionalContractsAreForwarded() async throws {
        let calls = CapabilityCallCount()
        let raw = CapabilityPlainEngine(calls: calls)
        let wrapped = DemoObservedInferenceEngine(engine: raw, observer: { _ in })
        let erased: any BoneInferenceEngine = wrapped
        #expect(!(erased is any BoneInferenceContextTokenCounting))
        do {
            _ = try await wrapped.inferUsingStream(request: CapabilityFixtures.request(), options: .init())
            Issue.record("An engine without real event streaming was accepted")
        } catch {
            #expect(error as? BoneInferenceError == .unsupportedCapability(.streaming))
        }
        #expect(await calls.count == 0)
        let capable = DemoObservedInferenceEngine(engine: CapabilityContextEngine(), observer: { _ in })
        #expect(try capable.contextBudget(for: "test")?.contextWindowTokens == 8_192)
        #expect(try await capable.countContextTokens(request: CapabilityFixtures.request()) == 123)
        let image = try CapabilityFixtures.image()
        #expect(try capable.imageTokens(for: image, modelID: "test") == 77)
        #expect(try capable.imageInputSafetyMarginTokens(for: "test") == 33)
        let continuation = try BoneInferenceProviderContinuation(provider: .custom, data: Data("opaque".utf8))
        #expect(try capable.rebindContextContinuation(continuation, from: [], to: []) == continuation)
        let resolved = try capable.resolvedCapabilities(for: CapabilityFixtures.request(), invocation: .nonStreaming)
        #expect(resolved.capabilities == [.text])
    }

    @Test
    func streamingCalculatorRoundResetsDraftAndRetainsToolHistory() async throws {
        var settings = CapabilityFixtures.settings()
        settings.enablesCalculator = true
        let stub = CapabilityHTTPStub([
            .events(try CapabilityFixtures.toolEvents()),
            .events(try CapabilityFixtures.textEvents(["结果为 ", "20。"])),
            .events(try CapabilityFixtures.textEvents(["仍为 20。"])),
        ])
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }
        )
        let reply = try await session.send("计算 12 + 8")
        #expect(reply.text == "结果为 20。")
        #expect(reply.steps == 2)
        #expect(reply.toolCalls == 1)
        #expect(await updates.drafts == [["准备计算"], ["结果为 ", "20。"]])
        #expect(await updates.phases.contains(.executingTools))
        #expect(!(await updates.phases.contains(.reasoning)))
        _ = try await session.send("刚才的结果？")
        let requests = await stub.requests
        try #require(requests.count == 3)
        let history = try CapabilityFixtures.messages(requests[2])
        #expect(history.compactMap { $0["role"] as? String } == ["user", "assistant", "tool", "assistant", "user"])
        let tool = try #require(history.first { $0["role"] as? String == "tool" })
        #expect(tool["tool_call_id"] as? String == "calculation-1")
        let output = try #require(tool["content"] as? String)
        #expect(try JSONDecoder().decode(DemoCalculatorTool.Output.self, from: Data(output.utf8)).value == 20)
        let statistics = await session.statistics()
        #expect(statistics.roundCount == 2)
        #expect(statistics.stepCount == 3)
        #expect(statistics.toolCallCount == 1)
        #expect(await stub.nonStreamingCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationAfterPartialTextLocksSessionAndPreventsPrivateExport() async throws {
        let channel = BoneInferenceRawEventStream.makeStream()
        let stub = CapabilityHTTPStub([.stream(channel.stream)])
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: CapabilityFixtures.settings(), apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }, bindingID: "test-binding"
        )
        let pending = Task { try await session.send("等待") }
        defer { pending.cancel(); channel.continuation.finish() }
        channel.continuation.yield(try CapabilityFixtures.delta(["content": "partial"]))
        await updates.waitForTextCount(1)
        pending.cancel()
        do { _ = try await pending.value; Issue.record("Cancelled text was committed") }
        catch { #expect(error as? DemoLiveChatFailure == .cancelled) }
        await stub.waitForCancellation()
        #expect(await CapabilityFixtures.failure(session) == .cancelled)
        do { _ = try await session.exportPrivateState(); Issue.record("Cancelled state was exportable") }
        catch { #expect(error as? DemoLiveChatFailure == .cancelled) }
        let statistics = await session.statistics()
        #expect(statistics.successfulRoundCount == 0)
        #expect(statistics.tokens.responseCount == 0)
        #expect(await stub.requests.count == 1)
        #expect(await stub.nonStreamingCalls == 0)
    }

    @Test(arguments: [false, true])
    func prematureEOFAndTruncationRejectPartialAnswersWithoutRetry(truncated: Bool) async throws {
        var events = [try CapabilityFixtures.delta(["content": "partial"])]
        if truncated { events += try CapabilityFixtures.ending(reason: "length") }
        let stub = CapabilityHTTPStub([.events(events)])
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: CapabilityFixtures.settings(), apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }
        )
        let expected: DemoLiveChatFailure = truncated ? .limitReached : .invalidResponse
        #expect(await CapabilityFixtures.failure(session) == expected)
        #expect(await CapabilityFixtures.failure(session) == expected)
        #expect(await updates.deltas == ["partial"])
        #expect(await session.statistics().successfulRoundCount == 0)
        #expect(await stub.requests.count == 1)
        #expect(await stub.nonStreamingCalls == 0)
    }

    @Test(arguments: [false, true])
    func sdkCompactionAndOptionalSummaryAreObservedAndBudgetAccounted(summarizes: Bool) async throws {
        var settings = CapabilityFixtures.settings()
        settings.managesContext = true
        settings.contextWindowTokens = 4_096
        settings.maximumOutputTokens = 128
        settings.summarizesContext = summarizes
        let oldQuestion = String(repeating: "a", count: 5_600)
        let oldAnswer = String(repeating: "b", count: 5_600)
        var replies: [CapabilityHTTPStub.Reply] = [.events(try CapabilityFixtures.textEvents([oldAnswer]))]
        if summarizes { replies.append(.json(try CapabilityFixtures.textResponse("Goals: retain confirmed facts."))) }
        replies.append(.events(try CapabilityFixtures.textEvents(["新回答"])))
        let stub = CapabilityHTTPStub(replies)
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }
        )
        _ = try await session.send(oldQuestion)
        let reply = try await session.send(String(repeating: "c", count: 2_000))
        #expect(reply.text == "新回答")
        #expect(await updates.phases.contains(.compactingContext))
        #expect(await updates.phases.contains(.summarizingContext) == summarizes)
        #expect(await updates.drafts == [[oldAnswer], ["新回答"]])
        let snapshots = await updates.tokens
        #expect(snapshots.contains { ($0.context?.revision ?? 0) > 0 })
        #expect(snapshots.contains { $0.context?.stage == .ready && $0.context?.source == .estimate })
        #expect(snapshots.contains { $0.context?.contextWindowTokens == 4_096 })
        #expect(snapshots.contains { ($0.context?.inputTokensBeforeCompaction ?? 0) > ($0.context?.inputTokens ?? 0) })
        let statistics = await session.statistics()
        #expect(statistics.roundCount == 2)
        #expect(statistics.stepCount == 2)
        #expect(statistics.summaryCallCount == (summarizes ? 1 : 0))
        #expect(statistics.tokens.requestCount == (summarizes ? 3 : 2))
        #expect(await stub.nonStreamingCalls == (summarizes ? 1 : 0))
        let requests = await stub.requests
        let finalRequest = try #require(requests.last)
        let finalHistory = try CapabilityFixtures.messages(finalRequest)
        #expect(!finalHistory.contains { $0["content"] as? String == oldQuestion })
        #expect(!finalHistory.contains { $0["content"] as? String == oldAnswer })
        if summarizes {
            let body = try CapabilityFixtures.body(requests[1])
            #expect(body["stream"] == nil)
            #expect((body["max_tokens"] as? Int ?? 0) <= 512)
            #expect(body["model"] as? String == settings.modelID)
            #expect(body["tools"] == nil)
            #expect(finalHistory.contains { ($0["content"] as? String)?.contains("Goals: retain confirmed facts.") == true })
        }
    }

    @Test
    func hostContextBudgetIntersectsCatalogLimitsWithoutClaimingOfficialCapacity() throws {
        let metadata = BoneModelMetadata(
            provenance: .init(source: .host, providerID: "test", retrievedAt: "2026-01-01", sourceURL: URL(string: "https://catalog.invalid")!),
            declaration: .init(id: "test", limits: .init(context: 8_192, input: 7_000, output: 2_048))
        )
        let model = BoneInferenceProviderCatalog.Model(
            id: "test", displayName: "Test", capabilities: [.chat], protocolVariant: .openAI, metadata: metadata
        )
        let budget = try DemoLiveChatSession.contextBudget(hostTokens: 32_768, model: model)
        #expect(budget.source == .host)
        #expect(budget.contextWindowTokens == 8_192)
        #expect(budget.maximumInputTokens == 7_000)
        #expect(budget.maximumOutputTokens == 2_048)
        let smaller = try DemoLiveChatSession.contextBudget(hostTokens: 4_096, model: model)
        #expect(smaller.contextWindowTokens == 4_096)
        #expect(smaller.maximumInputTokens == 4_096)
        let unknown = try DemoLiveChatSession.contextBudget(hostTokens: 32_768, model: nil)
        #expect(unknown.maximumInputTokens == nil)
        #expect(unknown.maximumOutputTokens == nil)
        #expect(unknown.source == .host)
    }

    @Test
    func privateRestorePreservesHistoryAndRejectsDifferentBindingsModelsAndTools() async throws {
        let settings = CapabilityFixtures.settings()
        let firstStub = CapabilityHTTPStub([.events(try CapabilityFixtures.textEvents(["已保存"]))])
        let first = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: firstStub, bindingID: "stable-binding"
        )
        _ = try await first.send("私有问题")
        let state = try await first.exportPrivateState()
        #expect(!String(decoding: state, as: UTF8.self).contains(CapabilityFixtures.key))
        let stub = CapabilityHTTPStub([.events(try CapabilityFixtures.textEvents(["继续回答"]))])
        let restored = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: stub,
            bindingID: "stable-binding", restoredState: state
        )
        #expect(await restored.statistics().isHistoryComplete == false)
        #expect(await restored.statistics().stepCount == 0)
        let reply = try await restored.send("继续")
        #expect(reply.text == "继续回答")
        let requests = await stub.requests
        let history = try CapabilityFixtures.messages(try #require(requests.first))
        #expect(history.compactMap { $0["content"] as? String } == ["私有问题", "已保存", "继续"])
        var changedModel = settings
        changedModel.modelID = "other-model"
        var changedTools = settings
        changedTools.enablesCalculator = true
        for (candidate, binding) in [(settings, "other-binding"), (changedModel, "stable-binding"), (changedTools, "stable-binding")] {
            do {
                _ = try await DemoLiveChatSession.make(
                    settings: candidate, apiKey: CapabilityFixtures.key, transport: stub,
                    bindingID: binding, restoredState: state
                )
                Issue.record("Mismatched private conversation was restored")
            } catch { #expect(error as? DemoLiveChatFailure == .invalidResponse) }
        }
        #expect(await stub.requests.count == 1)
    }

    @Test
    func resourceToolStaysStableAcrossLaterImportsAndOnlyVerifiedPreviewsEnterPrompt() async throws {
        var settings = CapabilityFixtures.settings()
        settings.enablesTextResources = true
        let store = DemoTextResourceStore()
        let stub = CapabilityHTTPStub([
            .events(try CapabilityFixtures.textEvents(["ready"])),
            .events(try CapabilityFixtures.textEvents(["preview accepted"]))
        ])
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: stub, textResources: store
        )
        _ = try await session.send("hello")
        let resource = try await store.add(name: "\"untrusted\".txt", text: String(repeating: "a", count: 5_000) + "PRIVATE FULL TAIL")
        _ = try await session.send("inspect preview", resources: [resource])
        let requests = await stub.requests
        let firstTools = try #require(CapabilityFixtures.body(requests[0])["tools"] as? [[String: Any]])
        let secondTools = try #require(CapabilityFixtures.body(requests[1])["tools"] as? [[String: Any]])
        #expect(try JSONSerialization.data(withJSONObject: firstTools, options: .sortedKeys)
            == JSONSerialization.data(withJSONObject: secondTools, options: .sortedKeys))
        let messages = try CapabilityFixtures.messages(requests[1])
        let prompt = try #require(messages.last?["content"] as? String)
        #expect(prompt.contains("untrusted data"))
        #expect(prompt.contains(resource.id))
        #expect(!prompt.contains("PRIVATE FULL TAIL"))
        let foreignStore = DemoTextResourceStore()
        let foreign = try await foreignStore.add(name: "foreign.txt", text: "not registered")
        do { _ = try await session.send("invalid attachment", resources: [foreign]); Issue.record("Foreign resource was accepted") }
        catch { #expect(error as? DemoLiveChatFailure == .invalidResponse) }
        #expect(await stub.requests.count == 2)
    }

    @Test(arguments: [DemoChatProvider.customOpenAI, .anthropic, .gemini])
    func configuredImagesReachConcreteProviderAndSDKContextObservation(provider: DemoChatProvider) async throws {
        var settings = CapabilityFixtures.settings()
        settings.selectProvider(provider)
        settings.baseURL = "https://live-capability.invalid"
        settings.modelID = "test-vision"
        settings.usesStreaming = false
        let image = try CapabilityFixtures.image()
        // Synthetic bytes/inspector exercise SDK wiring only; no recognition claim.
        let profile = try BoneInferenceImageInputProfile(
            contextBudget: .init(contextWindowTokens: 8_192, maximumOutputTokens: 1_024, source: .host),
            safetyMarginTokens: 100, tokenEstimator: { _ in 77 }
        )
        let imageConfiguration = try BoneInferenceImageInputConfiguration(
            profiles: [settings.modelID: profile],
            resolver: .init(inspect: { _ in image.reference.metadata }, load: { _ in Data(repeating: 42, count: 64) })
        )
        let response: String
        switch provider.kind {
        case .anthropic: response = #"{"type":"message","role":"assistant","content":[{"type":"text","text":"image reply"}],"stop_reason":"end_turn"}"#
        case .google: response = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"image reply"}]},"finishReason":"STOP"}]}"#
        default: response = try CapabilityFixtures.textResponse("image reply")
        }
        let stub = CapabilityHTTPStub([.json(response)])
        let updates = CapabilityUpdates()
        let session = try await DemoLiveChatSession.make(
            settings: settings, apiKey: CapabilityFixtures.key, transport: stub,
            observer: { await updates.receive($0) }, imageInputConfiguration: imageConfiguration
        )
        let reply = try await session.send("inspect", images: [image])
        #expect(reply.text == "image reply")
        let requests = await stub.requests
        let body = try #require(requests.first?.httpBody)
        #expect(String(decoding: body, as: UTF8.self).contains(Data(repeating: 42, count: 64).base64EncodedString()))
        #expect(await updates.tokens.contains { $0.context?.imageCount == 1 && $0.context?.source == .estimate })
        #expect(await updates.deltas.isEmpty)
    }
}

private enum CapabilityFixtures {
    static let key = "offline-unit-test-key"

    static func settings() -> DemoLiveChatSettings {
        var settings = DemoLiveChatSettings()
        settings.provider = .customOpenAI
        settings.baseURL = "https://live-capability.invalid"
        settings.modelID = "unit-test-model"
        settings.systemPrompt = ""
        settings.usesStreaming = true
        settings.managesContext = false
        return settings
    }

    static func request() -> BoneInferenceRequest {
        .init(modelID: "unit-test-model", messages: [.init(role: .user, content: "test")])
    }

    static func image() throws -> BoneInferenceImageInput {
        let metadata = try BoneInferenceImageMetadata(format: .png, width: 100, height: 100, byteCount: 64)
        let reference = try BoneInferencePreparedImage(data: Data(repeating: 42, count: 64), metadata: metadata)
            .reference(id: "test-image", version: "v1")
        return .init(reference: reference)
    }

    static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    static func delta(_ value: [String: Any]) throws -> BoneInferenceEventStreamEvent {
        .init(data: try json(["choices": [["index": 0, "delta": value]]]))
    }

    static func ending(reason: String = "stop") throws -> [BoneInferenceEventStreamEvent] {
        [
            .init(data: try json(["choices": [["index": 0, "delta": [:], "finish_reason": reason]]])),
            .init(data: try json(["choices": [], "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]])),
            .init(data: "[DONE]")
        ]
    }

    static func textEvents(_ fragments: [String]) throws -> [BoneInferenceEventStreamEvent] {
        try fragments.map { try delta(["content": $0]) } + ending()
    }

    static func toolEvents() throws -> [BoneInferenceEventStreamEvent] {
        let arguments = try json(["expression": "12 + 8"])
        return try [delta(["content": "准备计算"]), delta(["tool_calls": [[
            "index": 0, "id": "calculation-1", "type": "function",
            "function": ["name": "math_calculate", "arguments": arguments]
        ]]])] + ending(reason: "tool_calls")
    }

    static func textResponse(_ text: String) throws -> String {
        try json(["choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                  "usage": ["prompt_tokens": 3, "completion_tokens": 2, "total_tokens": 5]])
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func messages(_ request: URLRequest) throws -> [[String: Any]] {
        try #require(body(request)["messages"] as? [[String: Any]])
    }

    static func failure(_ session: DemoLiveChatSession) async -> DemoLiveChatFailure? {
        do { _ = try await session.send("try"); Issue.record("Expected safe failure"); return nil }
        catch { return error as? DemoLiveChatFailure }
    }
}

private actor CapabilityUpdates {
    private(set) var deltas: [String] = []
    private(set) var drafts: [[String]] = []
    private(set) var phases: [BoneAgentStatus.Phase] = []
    private(set) var tokens: [BoneAgentTokenSnapshot] = []
    private(set) var terminalCount = 0
    private var textWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func receive(_ update: DemoLiveChatUpdate) {
        switch update {
        case .inferenceStarted: drafts.append([])
        case .textDelta(let text):
            deltas.append(text)
            if !drafts.isEmpty { drafts[drafts.count - 1].append(text) }
            let ready = textWaiters.filter { deltas.count >= $0.0 }
            textWaiters.removeAll { deltas.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        case .status(let status):
            phases.append(status.phase)
            if status.isTerminal { terminalCount += 1 }
        case .tokens(let snapshot): tokens.append(snapshot)
        case .contextCompacted, .contextFailure: break
        }
    }

    func waitForTextCount(_ count: Int) async {
        if deltas.count >= count { return }
        await withCheckedContinuation { textWaiters.append((count, $0)) }
    }
}

private enum CapabilityStubError: Error { case unexpectedRequest }

/// Offline raw SSE injection, explicitly without live transport timing claims.
private actor CapabilityHTTPStub: BoneInferenceHTTPTransport {
    enum Reply: Sendable {
        case events([BoneInferenceEventStreamEvent])
        case stream(BoneInferenceRawEventStream)
        case json(String)
    }
    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private(set) var nonStreamingCalls = 0
    private var cancelled = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ replies: [Reply]) { self.replies = replies }

    private func next(_ request: URLRequest) throws -> Reply {
        requests.append(request)
        guard !replies.isEmpty else { throw CapabilityStubError.unexpectedRequest }
        return replies.removeFirst()
    }

    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        nonStreamingCalls += 1
        guard case .json(let text) = try next(request) else { throw CapabilityStubError.unexpectedRequest }
        return .init(statusCode: 200, data: Data(text.utf8), headers: ["content-type": "application/json"])
    }

    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        throw CapabilityStubError.unexpectedRequest
    }

    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        throw CapabilityStubError.unexpectedRequest
    }

    nonisolated func eventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceRawEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch try await self.next(request) {
                    case .events(let events):
                        for event in events { try Task.checkCancellation(); continuation.yield(event) }
                    case .stream(let stream):
                        for try await event in stream { try Task.checkCancellation(); continuation.yield(event) }
                    case .json: throw CapabilityStubError.unexpectedRequest
                    }
                    try Task.checkCancellation()
                    continuation.finish()
                } catch {
                    if Task.isCancelled { await self.recordCancellation() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private func recordCancellation() {
        cancelled = true
        let waiters = cancellationWaiters
        cancellationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func waitForCancellation() async {
        if cancelled { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }
}

private struct CapabilityEventEngine: BoneInferenceEngine, BoneInferenceEventStreaming {
    let events: [BoneInferenceStreamEvent]
    var nonImageCapabilities: Set<BoneInferenceCapability> { [.text, .streaming] }
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { throw CapabilityStubError.unexpectedRequest }
    func inferenceEvents(request: BoneInferenceRequest, options: BoneInferenceEventStreamOptions) -> BoneInferenceNormalizedEventStream {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

private actor CapabilityCallCount {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct CapabilityPlainEngine: BoneInferenceEngine {
    let calls: CapabilityCallCount
    var nonImageCapabilities: Set<BoneInferenceCapability> { [.text] }
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        await calls.record()
        return .init(text: "should never be used as fallback")
    }
}

private struct CapabilityContextEngine: BoneInferenceEngine, BoneInferenceContextBudgetProviding,
    BoneInferenceContextRebinding, BoneInferenceContextTokenCounting, BoneInferenceImageTokenProviding {
    var nonImageCapabilities: Set<BoneInferenceCapability> { [.text, .streaming] }
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse { .init(text: "answer") }
    func resolvedCapabilities(for request: BoneInferenceRequest, invocation: BoneInferenceInvocationMode) throws -> BoneResolvedInferenceCapabilities {
        .init(modelID: request.modelID, invocation: invocation, capabilities: [.text])
    }
    func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? {
        try .init(contextWindowTokens: 8_192, source: .host)
    }
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int { 123 }
    func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int { 77 }
    func imageInputSafetyMarginTokens(for modelID: String) throws -> Int { 33 }
    func rebindContextContinuation(_ continuation: BoneInferenceProviderContinuation,
                                   from original: [BoneInferenceMessage], to compacted: [BoneInferenceMessage]) throws -> BoneInferenceProviderContinuation? {
        continuation
    }
}
