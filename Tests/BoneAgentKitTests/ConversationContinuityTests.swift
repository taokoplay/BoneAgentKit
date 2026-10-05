import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

final class ConversationContinuityTests: XCTestCase {
    private func agent(_ engine: any BoneInferenceEngine, tools: [BoneAnyAgentTool] = [],
                       context: BoneContextManagementConfiguration? = nil, budget: BoneRunBudget? = nil) throws -> BoneAgent {
        BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: tools), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 4, runBudget: budget, inferenceCostEstimator: { _ in 0 }, contextManagement: context))
    }

    func testTextRoundTripPreservesHistoryOptionsIdentityAndRevision() async throws {
        let firstEngine = BoneScriptedInferenceEngine(script: [.init(text: "first answer")])
        let first = try await agent(firstEngine).makeConversation(modelID: "model", bindingID: "site-v1",
            systemMessages: [.init(role: .system, content: "Rules")], generationOptions: .init(temperature: 0.3, maximumOutputTokens: 100))
        _ = try await first.send("first question")
        let blob = try await first.exportPrivateState()
        let id = await first.id
        let secondEngine = BoneScriptedInferenceEngine(script: [.init(text: "second answer")])
        let secondAgent = try agent(secondEngine)
        let restored = try await secondAgent.restoreConversation(privateState: blob, modelID: "model", bindingID: "site-v1", expectedID: id, expectedRevision: 1)
        _ = try await restored.send("second question")
        let requests = await secondEngine.receivedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.messages.map { $0.content ?? $0.assistantTurn?.text ?? "" }, ["Rules", "first question", "first answer", "second question"])
        XCTAssertEqual(request.generationOptions, .init(temperature: 0.3, maximumOutputTokens: 100))
        let state = try BoneAgentConversationState.decode(await restored.exportPrivateState())
        XCTAssertEqual(state.revision, 2)
        XCTAssertEqual(state.id, id)
        XCTAssertEqual(state.messages.last?.assistantTurn?.text, "second answer")
    }

    func testLegacyToolResultsArePairedAndNotReplayedOnRestore() async throws {
        let tool = ConversationReadTool()
        let engine = BoneScriptedInferenceEngine(script: [.toolCall(.init(id: "c", toolID: tool.definition.id, arguments: Data("{}".utf8))), .init(text: "done")])
        let original = try await agent(engine, tools: [BoneAnyAgentTool(tool)]).makeConversation(modelID: "model", bindingID: "site")
        _ = try await original.send("read")
        let blob = try await original.exportPrivateState()
        let state = try BoneAgentConversationState.decode(blob)
        XCTAssertEqual(state.messages.map(\.role), [.user, .assistant, .tool, .assistant])
        let nextEngine = BoneScriptedInferenceEngine(script: [.init(text: "next")])
        let restored = try await agent(nextEngine, tools: [BoneAnyAgentTool(tool)]).restoreConversation(privateState: blob,
            modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 1)
        _ = try await restored.send("explain")
        let executions = await tool.counter.value
        XCTAssertEqual(executions, 1)
    }

    func testImportRejectsChangedBindingToolsVersionAndInvalidHistory() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "ok")])
        let subject = try agent(engine)
        let conversation = try await subject.makeConversation(modelID: "model", bindingID: "site")
        _ = try await conversation.send("question")
        let blob = try await conversation.exportPrivateState()
        let state = try BoneAgentConversationState.decode(blob)
        for (model, binding, revision) in [("other", "site", UInt64(1)), ("model", "other", 1), ("model", "site", 2)] {
            do { _ = try await subject.restoreConversation(privateState: blob, modelID: model, bindingID: binding, expectedID: state.id, expectedRevision: revision); XCTFail("mismatch") }
            catch { XCTAssertTrue(error is BoneAgentConversationError) }
        }
        let changedTools = try agent(engine, tools: [BoneAnyAgentTool(ConversationReadTool())])
        do { _ = try await changedTools.restoreConversation(privateState: blob, modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 1); XCTFail("tools") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .toolsChanged) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: blob) as? [String: Any])
        object["schemaVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: object)
        do { _ = try await subject.restoreConversation(privateState: future, modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 1); XCTFail("future") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .unsupportedVersion) }
        object["schemaVersion"] = 1
        object["messages"] = [["role": "user", "content": "incomplete"]]
        let invalid = try JSONSerialization.data(withJSONObject: object)
        do { _ = try await subject.restoreConversation(privateState: invalid, modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 1); XCTFail("invalid history") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .invalidState) }
        XCTAssertThrowsError(try BoneAgentConversationState.decode(Data(repeating: 0, count: BoneAgentConversation.maximumPrivateStateBytes + 1)))
    }

    func testFailedRunLocksConversationAndDoesNotPublishNewState() async throws {
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "ok")])
        let conversation = try await agent(engine).makeConversation(modelID: "model", bindingID: "site")
        _ = try await conversation.send("first")
        do { _ = try await conversation.send("second"); XCTFail("script exhausted") } catch {}
        let revision = await conversation.revision
        let phase = await conversation.phase
        XCTAssertEqual(revision, 1)
        XCTAssertEqual(phase, .recoveryRequired)
        do { _ = try await conversation.exportPrivateState(); XCTFail("failed state must not export") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .recoveryRequired) }
        do { _ = try await conversation.send("retry"); XCTFail("no blind retry") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .recoveryRequired) }
        let requests = await engine.receivedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func testEachCompletedUserTurnUsesANewRunBudget() async throws {
        let budget = try BoneRunBudget(maximumInferenceCalls: 1, maximumToolCalls: 1, maximumInputBytes: 100_000,
            maximumOutputBytes: 100_000, maximumTurns: 1, maximumWallClockSeconds: 30,
            maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 0)
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "one"), .init(text: "two")])
        let conversation = try await agent(engine, budget: budget).makeConversation(modelID: "model", bindingID: "site")
        _ = try await conversation.send("one")
        _ = try await conversation.send("two")
        let revision = await conversation.revision
        XCTAssertEqual(revision, 2)
    }

    func testBusyAndCancellationNeverExportOrRetryInFlightState() async throws {
        let engine = ConversationBlockingEngine()
        let conversation = try await agent(engine).makeConversation(modelID: "model", bindingID: "site")
        let task = Task { try await conversation.send("first") }
        await engine.waitUntilEntered()
        do { _ = try await conversation.send("concurrent"); XCTFail("busy") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .busy) }
        do { _ = try await conversation.exportPrivateState(); XCTFail("in flight") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        let phase = await conversation.phase
        let revision = await conversation.revision
        XCTAssertEqual(phase, .recoveryRequired)
        XCTAssertEqual(revision, 0)
    }

    func testGeminiFinalSignaturesSurviveRestoreWithAndWithoutTools() async throws {
        for withTools in [false, true] {
            let transport = ConversationGeminiTransport()
            let engine = BoneGeminiInferenceEngine(configuration: .init(kind: .google, apiKey: "synthetic", baseURL: URL(string: "https://synthetic.invalid")!, authenticationMode: .googleAPIKey), transport: transport)
            let tools = withTools ? [BoneAnyAgentTool(ConversationReadTool())] : []
            let subject = try agent(engine, tools: tools)
            let conversation = try await subject.makeConversation(modelID: "model", bindingID: "gemini-site")
            _ = try await conversation.send("first")
            let blob = try await conversation.exportPrivateState()
            let state = try BoneAgentConversationState.decode(blob)
            XCTAssertNotNil(state.providerContinuation)
            let next = try await subject.restoreConversation(privateState: blob, modelID: "model", bindingID: "gemini-site", expectedID: state.id, expectedRevision: 1)
            _ = try await next.send("second")
            let bodies = await transport.bodies
            let last = String(decoding: try XCTUnwrap(bodies.last), as: UTF8.self)
            XCTAssertTrue(last.contains("signature-1"))
            let completed = try BoneAgentConversationState.decode(await next.exportPrivateState())
            let replay = try BoneGeminiContinuation.partsByMessage(from: completed.providerContinuation, messages: completed.messages)
            XCTAssertEqual(replay.count, 2)
        }
    }

    func testConversationNeverLogsPrivateRequestsEvenWithSensitiveLoggingEnabled() async throws {
        let logger = ConversationLogger()
        let engine = BoneScriptedInferenceEngine(script: [.init(text: "private-answer")])
        let subject = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: []), toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 1, logging: .init(isDebugEnabled: true, minimumLevel: .debug, logger: logger, includesSensitivePayloads: true)))
        let conversation = try await subject.makeConversation(modelID: "model", bindingID: "site", systemMessages: [.init(role: .system, content: "private-system")])
        _ = try await conversation.send("private-user")
        for content in ["private-system", "private-user", "private-answer"] { XCTAssertFalse(logger.text.contains(content)) }
    }

    func testSummaryRestoresOnceAndRequiresContextPolicy() async throws {
        let budget = try BoneContextWindowBudget(contextWindowTokens: 512, maximumOutputTokens: 64, source: .host)
        let summaries = BoneScriptedInferenceEngine(script: [.init(text: "remembered")])
        let binding = try BoneInferenceEngineContextSummarizer(engine: summaries, modelID: "summary", budget: .init(contextWindowTokens: 4096, source: .host))
        let policy = try BoneContextManagementConfiguration(budgetProvider: { _ in budget }, summarizer: binding,
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 64)
        let engine = BoneScriptedInferenceEngine(script: [.init(text: String(repeating: "details ", count: 300)), .init(text: "two")])
        let conversation = try await agent(engine, context: policy).makeConversation(modelID: "model", bindingID: "site")
        _ = try await conversation.send("first")
        _ = try await conversation.send("second")
        let blob = try await conversation.exportPrivateState()
        let state = try BoneAgentConversationState.decode(blob)
        XCTAssertEqual(state.summary, "remembered")
        let next = BoneScriptedInferenceEngine(script: [.init(text: "three")])
        do { _ = try await agent(next).restoreConversation(privateState: blob, modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 2); XCTFail("policy required") }
        catch { XCTAssertEqual(error as? BoneAgentConversationError, .contextPolicyRequired) }
        let restored = try await agent(next, context: policy).restoreConversation(privateState: blob, modelID: "model", bindingID: "site", expectedID: state.id, expectedRevision: 2)
        _ = try await restored.send("third")
        let requests = await next.receivedRequests()
        XCTAssertEqual(requests.first?.messages.filter { $0.content?.contains("Historical summary") == true }.count, 1)
        let calls = await summaries.receivedRequests()
        XCTAssertEqual(calls.count, 1)
    }
}
private actor ConversationReadCounter { var value = 0; func increment() { value += 1 } }
private struct ConversationReadTool: BoneAgentTool {
    struct Payload: Codable, Sendable {}
    typealias Input = Payload
    typealias Output = Payload
    typealias Context = BoneAgentEmptyContext
    let counter = ConversationReadCounter()
    static let definition = BoneAgentToolDefinition(id: "conversation.read", version: "1", title: "Read", summary: "Read synthetic",
        wireName: "read", schemaVersion: 1, inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    var definition: BoneAgentToolDefinition { Self.definition }
    func execute(input: Input, context: Context) async throws -> Output { await counter.increment(); return .init() }
}

private actor ConversationBlockingEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        entered = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return .init(text: "late")
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
private actor ConversationGeminiTransport: BoneInferenceHTTPTransport {
    var bodies: [Data] = []
    func send(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse {
        bodies.append(request.httpBody ?? Data())
        let response: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["role": "model", "parts": [["text": "same answer", "thoughtSignature": "signature-\(bodies.count)"]]]]]]
        return .init(statusCode: 200, data: try JSONSerialization.data(withJSONObject: response))
    }
    func sendRetryableForModels(_ request: URLRequest) async throws -> BoneInferenceHTTPResponse { try await send(request) }
    func sendEventStream(_ request: URLRequest, options: BoneInferenceEventStreamOptions) async throws -> BoneInferenceEventStreamResponse {
        throw BoneInferenceTransportError.invalidConfiguration
    }
}
private final class ConversationLogger: BoneAgentLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String, context: BoneAgentLogContext?) {
        lock.lock(); defer { lock.unlock() }; lines.append(message() + String(describing: context?.values))
    }
}
