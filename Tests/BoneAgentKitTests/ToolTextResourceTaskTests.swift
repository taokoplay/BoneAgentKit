import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

/// 实际 Agent + 资源 Tool + 上下文压缩 + 独立结果验收；模型决策由读取真实消息的离线替身驱动。
final class ToolTextResourceTaskTests: XCTestCase {
    func testLargeResultUsesPreviewAndReadsTailBeforeDelivering() async throws {
        let snapshot = try Self.snapshot()
        XCTAssertGreaterThan(snapshot.reference.utf8ByteCount, BoneInferenceToolResult.maximumResultByteCount)
        let store = ResourceTaskStore(snapshot: snapshot)
        let engine = Self.engine(compacts: false)
        let agent = try Self.agent(engine: engine, store: store)
        let result = try await agent.run(modelID: "resource-task", messages: Self.messages)
        let validated = try await Self.validate(result.output)
        guard case .accepted(let total) = validated.validation else { return XCTFail("Expected independent total check") }
        XCTAssertEqual(total, 100)
        XCTAssertEqual(result.steps, 3)
        let requests = await engine.requests()
        let discovery: BoneToolTextResourcePreview = try Self.result(requests[1], callID: "discover")
        XCTAssertTrue(discovery.isTruncated)
        XCTAssertLessThanOrEqual(discovery.text.utf8.count, 64)
        XCTAssertFalse(discovery.text.contains("VALUES="))
        let page: BoneToolTextResourcePage = try Self.result(requests[2], callID: "read")
        XCTAssertNil(page.nextOffset)
        XCTAssertTrue(page.text.contains("VALUES=17,23,60"))
        XCTAssertEqual(page.reference, discovery.reference)
        XCTAssertEqual(page.offset, snapshot.reference.utf8ByteCount - 96)
        let observations = await store.observations()
        XCTAssertEqual(observations.lookups, 1)
        XCTAssertEqual(observations.reads, 1)
        let transmittedBytes = try requests.map { try JSONEncoder().encode($0).count }.reduce(0, +)
        XCTAssertLessThan(transmittedBytes, snapshot.reference.utf8ByteCount / 10)
        XCTAssertEqual(validated.receipt.correctionAttemptCount, 0)
    }

    func testCompactionRemovesOldCardButSummaryReferenceRecoversExactData() async throws {
        let store = ResourceTaskStore(snapshot: try Self.snapshot())
        let engine = Self.engine(compacts: true)
        let summarizer = ResourceTaskSummaryEngine(preservesReference: true)
        let receipts = ResourceTaskReceipts()
        let agent = try Self.agent(engine: engine, store: store,
            contextManagement: Self.contextConfiguration(summary: summarizer, receipts: receipts))
        let result = try await agent.run(modelID: "resource-task", messages: Self.messages)
        XCTAssertEqual(result.steps, 5)
        let checked = try await Self.validate(result.output)
        guard case .accepted(let total) = checked.validation else { return XCTFail("Compressed task must retain its answer") }
        XCTAssertEqual(total, 100)
        let requests = await engine.requests()
        let afterCompaction = requests[3]
        XCTAssertEqual(afterCompaction.messages.first, Self.messages.first)
        XCTAssertTrue(afterCompaction.messages.contains(Self.messages[1]))
        XCTAssertFalse(Self.results(afterCompaction).contains { $0.callID == "discover" })
        XCTAssertFalse(Self.results(afterCompaction).contains { $0.callID == "noise-1" })
        XCTAssertTrue(Self.results(afterCompaction).contains { $0.callID == "noise-2" })
        let reference = try Self.summaryReference(afterCompaction)
        XCTAssertGreaterThan(reference.utf8ByteCount, 1_048_576)
        let page: BoneToolTextResourcePage = try Self.result(try XCTUnwrap(requests.last), callID: "read")
        XCTAssertEqual(page.reference, reference)
        let recorded = await receipts.values()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertTrue(try XCTUnwrap(recorded.first).usedModelSummary)
        XCTAssertEqual(recorded.first?.removedToolExchangeCount, 2)
        XCTAssertGreaterThan(recorded.first?.estimatedRequestTokenReduction ?? 0, 0)
        let summaryRequests = await summarizer.requests()
        XCTAssertEqual(summaryRequests.count, 1)
        XCTAssertTrue(summaryRequests[0].availableTools.isEmpty)
        let observations = await store.observations()
        XCTAssertEqual(observations.lookups, 1, "Must not replay the lookup after compaction")
        XCTAssertEqual(observations.reads, 1)
        XCTAssertLessThan(try JSONEncoder().encode(afterCompaction).count, 20_000)
    }

    func testLostReferenceInSummaryDoesNotProduceAnInventedSuccess() async throws {
        let store = ResourceTaskStore(snapshot: try Self.snapshot())
        let engine = Self.engine(compacts: true)
        let summarizer = ResourceTaskSummaryEngine(preservesReference: false)
        let receipts = ResourceTaskReceipts()
        let events = BoneAgentEventRecorder()
        let agent = try Self.agent(engine: engine, store: store, events: events,
            contextManagement: Self.contextConfiguration(summary: summarizer, receipts: receipts))
        do {
            _ = try await agent.run(modelID: "resource-task", messages: Self.messages)
            XCTFail("No reference means no justified read or final answer")
        } catch { XCTAssertEqual(error as? BoneAgentError, .inferenceFailed) }
        let observations = await store.observations()
        XCTAssertEqual(observations.reads, 0)
        let recorded = await events.events()
        XCTAssertFalse(recorded.contains(.runFinished(.succeeded)))
        let compacted = await receipts.values()
        XCTAssertTrue(compacted.contains { $0.usedModelSummary })
    }

    func testExpiredDeniedAndReplacedResourcesNeverReachNextInference() async throws {
        for behavior in [ResourceTaskStore.Behavior.expired, .denied, .replaced] {
            let store = ResourceTaskStore(snapshot: try Self.snapshot(), behavior: behavior)
            let engine = Self.engine(compacts: false)
            let events = BoneAgentEventRecorder()
            let agent = try Self.agent(engine: engine, store: store, events: events)
            do {
                _ = try await agent.run(modelID: "resource-task", messages: Self.messages)
                XCTFail("Unavailable or wrong version must stop before final output")
            } catch { XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed) }
            let requests = await engine.requests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(requests.contains { Self.results($0).contains { $0.callID == "read" } })
            let observations = await store.observations()
            XCTAssertEqual(observations.reads, 1, "No retry or latest-version fallback")
            let recorded = await events.events()
            XCTAssertFalse(recorded.contains(.runFinished(.succeeded)))
        }
    }

    func testResourceToolRequiresExplicitImpactPolicyBeforeLoading() async throws {
        let snapshot = try Self.snapshot()
        let store = ResourceTaskStore(snapshot: snapshot)
        let read = try BoneToolTextResourceReadRequest(reference: snapshot.reference, maximumBytes: 64)
        let engine = ResourceTaskEngine(steps: [{ _ in try Self.call("read", input: read, toolID: Self.readToolID) }])
        let agent = BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: [Self.readTool()]),
            toolContext: ResourceTaskContext(store: store, scope: "allowed"),
            configuration: try .init(maximumSteps: 2))
        do {
            _ = try await agent.run(modelID: "resource-task", messages: Self.messages)
            XCTFail("Default impact policy cannot expose private data")
        } catch { XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed) }
        let observations = await store.observations()
        XCTAssertEqual(observations.reads, 0)
    }

    func testPagedReadsUseExistingToolBudgetAndStopBeforeSecondLoad() async throws {
        let snapshot = try Self.snapshot()
        let store = ResourceTaskStore(snapshot: snapshot)
        let read = try BoneToolTextResourceReadRequest(reference: snapshot.reference, maximumBytes: 64)
        let engine = ResourceTaskEngine(steps: [
            { _ in try Self.call("page-1", input: read, toolID: Self.readToolID) },
            { request in
                let first: BoneToolTextResourcePage = try Self.result(request, callID: "page-1")
                let next = try XCTUnwrap(first.nextOffset)
                return try Self.call("page-2", input: BoneToolTextResourceReadRequest(reference: first.reference,
                    offset: next, maximumBytes: 64), toolID: Self.readToolID)
            }
        ])
        let events = BoneAgentEventRecorder()
        let budget = try BoneRunBudget(maximumInferenceCalls: 3, maximumToolCalls: 1,
            maximumInputBytes: 100_000, maximumOutputBytes: 100_000, maximumTurns: 3,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 1, maximumEstimatedCostMicrounits: 10)
        let agent = try Self.agent(engine: engine, store: store, events: events, budget: budget)
        do {
            _ = try await agent.run(modelID: "resource-task", messages: Self.messages)
            XCTFail("Paging cannot bypass tool-call limits")
        } catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
        let observations = await store.observations()
        XCTAssertEqual(observations.reads, 1)
        let recorded = await events.events()
        XCTAssertEqual(recorded.last, .runFinished(.failed(.budgetExceeded)))
    }

    func testAnswerStillNeedsIndependentValidationAfterSuccessfulRead() async throws {
        let store = ResourceTaskStore(snapshot: try Self.snapshot())
        let engine = Self.engine(compacts: false, wrongTotal: true)
        let agent = try Self.agent(engine: engine, store: store)
        let result = try await agent.run(modelID: "resource-task", messages: Self.messages)
        let checked = try await Self.validate(result.output)
        guard case .rejected(let report) = checked.validation else { return XCTFail("Retrieval alone does not prove the answer") }
        XCTAssertEqual(report.issue, .contractMismatch)
        XCTAssertEqual(checked.receipt.correctionAttemptCount, 0)
        let observations = await store.observations()
        XCTAssertEqual(observations.reads, 1)
    }

    private static let messages: [BoneInferenceMessage] = [
        .init(role: .system, content: "Use source bytes, do not invent missing values. Keep the result local."),
        .init(role: .user, content: "Find the report and sum the integers on its final VALUES line. Return the values and total.")
    ]
    private static var readToolID: String { BoneToolTextResourceReadTool<ResourceTaskContext>.definition.id }

    private static func snapshot() throws -> BoneToolTextResourceSnapshot {
        try .init(id: "report-" + UUID().uuidString, version: "v1",
                  text: "Synthetic report header\n" + String(repeating: "unused row\n", count: 110_000) + "VALUES=17,23,60\n")
    }

    private static func contextConfiguration(summary: ResourceTaskSummaryEngine, receipts: ResourceTaskReceipts) throws -> BoneContextManagementConfiguration {
        let budget = try BoneContextWindowBudget(contextWindowTokens: 6_000, maximumOutputTokens: 256, source: .host)
        let summarizer = try BoneInferenceEngineContextSummarizer(engine: summary, modelID: "resource-summary",
            budget: .init(contextWindowTokens: 16_384, source: .host))
        return try .init(budgetProvider: { _ in budget }, summarizer: summarizer,
            protocolReserveTokens: 0, safetyMarginTokens: 0, maximumSummaryOutputTokens: 256,
            fallbackToTrimming: false, minimumRecentToolExchangeCount: 1,
            receiptSink: { await receipts.append($0) })
    }

    private static func readTool() -> BoneAnyAgentTool {
        BoneAnyAgentTool(BoneToolTextResourceReadTool<ResourceTaskContext>(reader: .init { request, context in
            try await context.store.read(request, scope: context.scope)
        }))
    }

    private static func agent(engine: ResourceTaskEngine, store: ResourceTaskStore,
                              events: BoneAgentEventRecorder = .init(),
                              contextManagement: BoneContextManagementConfiguration? = nil,
                              budget: BoneRunBudget? = nil) throws -> BoneAgent {
        BoneAgent(inferenceEngine: engine, toolRegistry: try .init(tools: [
            BoneAnyAgentTool(ResourceTaskLookupTool()), BoneAnyAgentTool(ResourceTaskNoiseTool()), readTool()
        ]), toolContext: ResourceTaskContext(store: store, scope: "allowed"),
        configuration: try .init(maximumSteps: 6, runBudget: budget,
            toolImpactPolicy: .init(maximumAllowed: BoneToolTextResourceReadTool<ResourceTaskContext>.definition.requiredImpact()),
            inferenceCostEstimator: { _ in 1 }, contextManagement: contextManagement), eventSink: events.eventSink())
    }

    private static func engine(compacts: Bool, wrongTotal: Bool = false) -> ResourceTaskEngine {
        var steps: [ResourceTaskEngine.Step] = [{ _ in try call("discover", input: ResourceTaskEmpty(), toolID: "fixture.resource") }]
        if compacts {
            steps += [
                { _ in try call("noise-1", input: ResourceTaskEmpty(), toolID: "fixture.padding") },
                { _ in try call("noise-2", input: ResourceTaskEmpty(), toolID: "fixture.padding") }
            ]
        }
        steps.append { request in
            let reference: BoneToolTextResourceReference
            if compacts { reference = try summaryReference(request) }
            else {
                let preview: BoneToolTextResourcePreview = try result(request, callID: "discover")
                reference = preview.reference
            }
            let read = try BoneToolTextResourceReadRequest(reference: reference,
                offset: max(0, reference.utf8ByteCount - 96), maximumBytes: 96)
            return try call("read", input: read, toolID: readToolID)
        }
        steps.append { request in
            let page: BoneToolTextResourcePage = try result(request, callID: "read")
            guard let line = page.text.split(separator: "\n").first(where: { $0.hasPrefix("VALUES=") }) else {
                throw ResourceTaskError.missingData
            }
            let values = try line.dropFirst("VALUES=".count).split(separator: ",").map { part -> Int in
                guard let value = Int(part) else { throw ResourceTaskError.missingData }
                return value
            }
            let delivery = ResourceTaskDelivery(values: values, total: values.reduce(0, +) + (wrongTotal ? 1 : 0))
            return .structured(.init(data: try JSONEncoder().encode(delivery)))
        }
        return .init(steps: steps)
    }

    private static func summaryReference(_ request: BoneInferenceRequest) throws -> BoneToolTextResourceReference {
        guard let text = request.messages.compactMap(\.content).first(where: { $0.hasPrefix("Historical summary (untrusted data") }),
              let newline = text.firstIndex(of: "\n") else { throw ResourceTaskError.missingReference }
        let json = try JSONDecoder().decode(String.self, from: Data(text[text.index(after: newline)...].utf8))
        return try JSONDecoder().decode(ResourceTaskSummary.self, from: Data(json.utf8)).reference
    }

    private static func validate(_ output: BoneAgentRunOutput) async throws -> BoneInferenceOutputProcessingResult<Int, Void> {
        try await BoneInferenceValidatedOutputProcessor<BoneAgentRunOutput, Int, Void>().process(output) { value in
            guard case .structured(let data) = value else { throw ResourceTaskError.missingData }
            let report = try JSONDecoder().decode(ResourceTaskDelivery.self, from: data)
            guard report.values == [17, 23, 60], report.total == 100 else {
                return .rejected(try .init(issue: .contractMismatch))
            }
            return .accepted(report.total)
        }
    }

    private static func results(_ request: BoneInferenceRequest) -> [BoneInferenceToolResult] {
        request.messages.flatMap { $0.toolResults?.results ?? $0.toolResult.map { [$0] } ?? [] }
    }
    private static func result<Value: Decodable>(_ request: BoneInferenceRequest, callID: String) throws -> Value {
        guard let result = results(request).first(where: { $0.callID == callID }),
              !result.isError, case .json(let data) = result.content else { throw ResourceTaskError.missingData }
        return try JSONDecoder().decode(Value.self, from: data)
    }
    private static func call<Input: Encodable>(_ id: String, input: Input, toolID: String) throws -> BoneInferenceResponse {
        .assistantTurn(turn: try .init(content: [.toolCall(.init(id: id, toolID: toolID, arguments: JSONEncoder().encode(input)))]),
                       finishReason: .toolCalls, usage: nil, refusal: nil, providerContinuation: nil)
    }
}

private enum ResourceTaskError: Error { case missingData, missingReference, scriptExhausted }
private struct ResourceTaskEmpty: Codable, Sendable {}
private struct ResourceTaskDelivery: Codable, Sendable { let values: [Int]; let total: Int }
private struct ResourceTaskSummary: Codable, Sendable { let reference: BoneToolTextResourceReference }
private struct ResourceTaskContext: BoneAgentToolContext { let store: ResourceTaskStore; let scope: String }

private actor ResourceTaskStore {
    enum Behavior { case normal, expired, denied, replaced }
    private let snapshot: BoneToolTextResourceSnapshot
    private let behavior: Behavior
    private var lookups = 0
    private var reads = 0
    init(snapshot: BoneToolTextResourceSnapshot, behavior: Behavior = .normal) { self.snapshot = snapshot; self.behavior = behavior }
    func preview(scope: String) throws -> BoneToolTextResourcePreview {
        guard scope == "allowed" else { throw BoneToolTextResourceError.accessDenied }
        lookups += 1
        return try snapshot.preview(maximumBytes: 64)
    }
    func read(_ request: BoneToolTextResourceReadRequest, scope: String) throws -> BoneToolTextResourcePage {
        reads += 1
        guard scope == "allowed" else { throw BoneToolTextResourceError.accessDenied }
        switch behavior {
        case .normal: return try snapshot.page(for: request)
        case .expired: throw BoneToolTextResourceError.expired
        case .denied: throw BoneToolTextResourceError.accessDenied
        case .replaced:
            let wrong = try BoneToolTextResourceReference(id: snapshot.reference.id, version: "v2", utf8ByteCount: snapshot.reference.utf8ByteCount)
            return try .init(reference: wrong, offset: request.offset, text: "wrong version")
        }
    }
    func observations() -> (lookups: Int, reads: Int) { (lookups, reads) }
}

private struct ResourceTaskLookupTool: BoneAgentTool {
    typealias Input = ResourceTaskEmpty
    typealias Output = BoneToolTextResourcePreview
    typealias Context = ResourceTaskContext
    static let definition = BoneAgentToolDefinition(id: "fixture.resource", version: "1", title: "Find report",
        summary: "Return a bounded preview and exact resource reference", wireName: "fixture_resource", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false),
        impact: .init(dataAccess: .userPrivate, externalTransmission: .none, stateChange: .none,
            economic: .none, userVisible: .none, permissionChange: .none))
    func execute(input: Input, context: Context) async throws -> Output { try await context.store.preview(scope: context.scope) }
}
private struct ResourceTaskNoiseTool: BoneAgentTool {
    typealias Input = ResourceTaskEmpty
    typealias Output = String
    typealias Context = ResourceTaskContext
    static let definition = BoneAgentToolDefinition(id: "fixture.padding", version: "1", title: "Read fixture details",
        summary: "Return irrelevant fixture detail to exercise compaction", wireName: "fixture_padding", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    func execute(input: Input, context: Context) async throws -> Output { String(repeating: "padding ", count: 1_050) }
}
private actor ResourceTaskEngine: BoneInferenceEngine {
    typealias Step = @Sendable (BoneInferenceRequest) throws -> BoneInferenceResponse
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .structuredOutput]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let steps: [Step]
    private var received: [BoneInferenceRequest] = []
    init(steps: [Step]) { self.steps = steps }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let index = received.count
        received.append(request)
        guard steps.indices.contains(index) else { throw ResourceTaskError.scriptExhausted }
        return try steps[index](request)
    }
    func requests() -> [BoneInferenceRequest] { received }
}
private actor ResourceTaskSummaryEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let preservesReference: Bool
    private var received: [BoneInferenceRequest] = []
    init(preservesReference: Bool) { self.preservesReference = preservesReference }
    func infer(request: BoneInferenceRequest) throws -> BoneInferenceResponse {
        received.append(request)
        guard preservesReference else { return .finish(.init(text: "A report was found; its reference was omitted.")) }
        struct History: Decodable { let messages: [BoneInferenceMessage] }
        let body = try XCTUnwrap(request.messages.last?.content)
        let history = try JSONDecoder().decode(History.self, from: Data(body.utf8))
        let results = history.messages.flatMap { $0.toolResults?.results ?? $0.toolResult.map { [$0] } ?? [] }
        guard let result = results.first(where: { $0.callID == "discover" }), case .json(let data) = result.content else {
            throw ResourceTaskError.missingReference
        }
        let card = try JSONDecoder().decode(BoneToolTextResourcePreview.self, from: data)
        let summary = try JSONEncoder().encode(ResourceTaskSummary(reference: card.reference))
        return .finish(.init(text: String(decoding: summary, as: UTF8.self)))
    }
    func requests() -> [BoneInferenceRequest] { received }
}
private actor ResourceTaskReceipts {
    private var receipts: [BoneContextCompactionReceipt] = []
    func append(_ receipt: BoneContextCompactionReceipt) { receipts.append(receipt) }
    func values() -> [BoneContextCompactionReceipt] { receipts }
}
