import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

/// 离线任务级验收：真实 Agent/Registry/Tool/预算/校验器，确定性的请求驱动模型替身。
/// 模型替身从实际 Tool Result 计算后续参数和最终值，不返回预写的成功答案。
/// 任务完成由独立 fixture 预期值判定；此套件不证明真实模型的自主规划能力。
final class AgentTaskAcceptanceTests: XCTestCase {
    func testReadCalculateAndDeliverExactTotalsAcrossThreeInputs() async throws {
        let cases: [([Int], Int)] = [([1_250, 500, 250], 2_000), ([17, 23, 60], 100), ([], 0)]
        for (values, expectedTotal) in cases {
            let store = TaskFixtureStore(series: ["invoice": values])
            let engine = TaskDrivenEngine(steps: [
                { request in
                    XCTAssertEqual(Set(request.availableTools.map(\.id)), [ReadSeriesTool.definition.id, SumSeriesTool.definition.id])
                    return try Self.calls([Self.readCall("invoice", id: "read")])
                },
                { request in
                    let read: Series = try Self.toolValue(request, callID: "read")
                    return try Self.calls([Self.call(SumSeriesTool.definition.id, id: "sum", input: read)])
                },
                { request in
                    let read: Series = try Self.toolValue(request, callID: "read")
                    let sum: Total = try Self.toolValue(request, callID: "sum")
                    return try Self.final(Delivery(records: read.values, total: sum.value))
                }
            ])
            let events = BoneAgentEventRecorder()
            let agent = try Self.agent(engine: engine, store: store, events: events)
            let run = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "读取账单并计算总额，返回逐项金额和合计。")])
            let checked = try await Self.validate(run.output, records: values, total: expectedTotal)
            guard case .accepted(let report) = checked.validation else { return XCTFail("Expected independently verified delivery") }
            XCTAssertEqual(report.total, expectedTotal)
            XCTAssertEqual(run.steps, 3)
            XCTAssertEqual(checked.receipt.correctionAttemptCount, 0)
            let trace = await store.actions()
            XCTAssertEqual(trace, ["read:invoice", "sum:\(values.count)"])
            let requests = await engine.requests()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(Self.toolResults(requests[2]).map(\.callID), ["read", "sum"])
            let recorded = await events.events()
            XCTAssertEqual(recorded.filter { $0 == .toolCallFinished }.count, 2)
            XCTAssertEqual(recorded.last, .runFinished(.succeeded))
        }
    }

    func testTwoSourcesMergeWithoutLosingOrDuplicatingRecords() async throws {
        let store = TaskFixtureStore(series: ["left": [7, 2, 7], "right": [3, 2, 9]])
        let engine = TaskDrivenEngine(steps: Self.mergeSteps(omitLast: false))
        let agent = try Self.agent(engine: engine, store: store, parallel: true)
        let run = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "读取两个来源，去重排序并汇总。")])
        let checked = try await Self.validate(run.output, records: [2, 3, 7, 9], total: 21)
        guard case .accepted(let report) = checked.validation else { return XCTFail("Expected complete merge") }
        XCTAssertEqual(report.records, [2, 3, 7, 9])
        XCTAssertTrue(report.complete)
        XCTAssertTrue(report.missingSources.isEmpty)
        XCTAssertEqual(run.steps, 2)
        let trace = await store.actions()
        XCTAssertEqual(trace.sorted(), ["read:left", "read:right"])
        let requests = await engine.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(Self.toolResults(requests[1]).map(\.callID), ["left", "right"])
        XCTAssertEqual(Self.toolResults(requests[1]).map(\.ordinal), [0, 1])
    }

    func testMissingRecordIsCorrectedOnceBeforeHostArtifactCommit() async throws {
        let store = TaskFixtureStore(series: ["left": [7, 2, 7], "right": [3, 2, 9]])
        let engine = TaskDrivenEngine(steps: Self.mergeSteps(omitLast: true) + [
            { request in
                let repair = try JSONDecoder().decode(RepairInput.self,
                    from: Data(try XCTUnwrap(request.messages.last?.content).utf8))
                XCTAssertEqual(repair.missingRecords, [9])
                XCTAssertEqual(repair.sourceRecords, [2, 3, 7, 9])
                let records = Array(Set(repair.sourceRecords)).sorted()
                return try Self.final(Delivery(records: records, total: records.reduce(0, +)))
            }
        ])
        let agent = try Self.agent(engine: engine, store: store)
        let run = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "合并两个来源，必须保留所有不同记录。")])
        let first = try Self.decode(run.output)
        XCTAssertEqual(first.records, [2, 3, 7])
        let requests = await engine.requests()
        let originalRequest = try XCTUnwrap(requests.last)
        let left: Series = try Self.toolValue(originalRequest, callID: "left")
        let right: Series = try Self.toolValue(originalRequest, callID: "right")
        let sourceRecords = Array(Set(left.values + right.values)).sorted()
        let processor = BoneInferenceValidatedOutputProcessor<BoneAgentRunOutput, Delivery, [Int]>()
        let rejected = try await processor.process(run.output) {
            try Self.check($0, records: [2, 3, 7, 9], total: 21)
        }
        guard case .rejected(let missing) = rejected.validation else { return XCTFail("Initial omission must be detected") }
        XCTAssertEqual(missing.feedback, [9])

        // 修正直调 Engine；调用方显式提供独立且有限的预算，不让新的 Agent Run 重置原额度。
        let meter = BoneRunBudgetMeter(budget: try Self.budget(inferences: 1, tools: 1))
        let result = try await processor.process(run.output, policy: .init(maximumCorrectionAttempts: 1),
            validate: { try Self.check($0, records: [2, 3, 7, 9], total: 21) },
            correct: { _, report, attempt in
                XCTAssertEqual(attempt, 1)
                let input = RepairInput(sourceRecords: sourceRecords, missingRecords: report.feedback ?? [])
                let message = String(decoding: try JSONEncoder().encode(input), as: UTF8.self)
                let request = BoneInferenceRequest(modelID: "task-fixture", messages: [.init(role: .user, content: message)])
                try await meter.reserveInference(inputBytes: JSONEncoder().encode(request).count, estimatedCostMicrounits: 1)
                try Task.checkCancellation()
                let response = try await engine.infer(request: request)
                try await meter.commitInference(outputBytes: JSONEncoder().encode(response).count)
                try Task.checkCancellation()
                guard case .structured(let structured) = response else { throw TaskFixtureError.invalidResult }
                return .structured(structured.data)
            })
        guard case .accepted(let report) = result.validation else { return XCTFail("Repair must satisfy the independent oracle") }
        XCTAssertEqual(result.receipt.validationCount, 2)
        XCTAssertEqual(result.receipt.correctionAttemptCount, 1)
        XCTAssertEqual(report.records, [2, 3, 7, 9])
        XCTAssertEqual(report.total, 21)

        // 文件由测试 Host 在验收通过后提交；不是让模型绕过授权自行写文件。
        let parent = ProcessInfo.processInfo.environment["PI_SCRATCH_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent("agent-delivery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("verified-report.json")
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        let reopened = try JSONDecoder().decode(Delivery.self, from: Data(contentsOf: url))
        XCTAssertEqual(reopened, Delivery(records: [2, 3, 7, 9], total: 21))
        let finalRequests = await engine.requests()
        XCTAssertEqual(finalRequests.count, 3)
        let actions = await store.actions()
        XCTAssertEqual(actions, ["read:left", "read:right"], "Repair must not replay the tools")
    }

    func testOptionalSourceFailureDeliversRequiredDataWithExplicitGap() async throws {
        let store = TaskFixtureStore(series: ["required": [10, 20]])
        let engine = TaskDrivenEngine(steps: [
            { _ in try Self.calls([Self.readCall("required", id: "required"), Self.readCall("optional", id: "optional", ordinal: 1)]) },
            { request in
                let results = Self.toolResults(request)
                XCTAssertEqual(results.count, 2)
                XCTAssertFalse(results[0].isError)
                XCTAssertTrue(results[1].isError)
                let required: Series = try Self.toolValue(request, callID: "required")
                return try Self.final(Delivery(records: required.values, total: required.values.reduce(0, +),
                    missingSources: ["optional"], complete: false))
            }
        ])
        let agent = try Self.agent(engine: engine, store: store, failureStrategy: .collectAll)
        let run = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "汇总必需来源；可选来源失败时明确标注缺口。")])
        let report = try Self.decode(run.output)
        // 独立契约允许此可选缺口，但禁止冒充完整扫描。
        XCTAssertEqual(report, Delivery(records: [10, 20], total: 30, missingSources: ["optional"], complete: false))
        let requests = await engine.requests()
        XCTAssertEqual(requests.count, 2)
        let actions = await store.actions()
        XCTAssertEqual(actions, ["read:required", "read:optional"])
    }

    func testIncorrectFinalAnswerIsRejectedDespiteSuccessfulAgentRun() async throws {
        let store = TaskFixtureStore(series: ["input": [4, 6]])
        let engine = TaskDrivenEngine(steps: [
            { _ in try Self.calls([Self.readCall("input", id: "read")]) },
            { request in
                let source: Series = try Self.toolValue(request, callID: "read")
                // 故意注入“算错但说完成”的模型缺陷。
                return try Self.final(Delivery(records: source.values, total: source.values.reduce(0, +) + 1))
            },
            { request in
                XCTAssertTrue(try XCTUnwrap(request.messages.last?.content).contains("total"))
                return try Self.final(Delivery(records: [4, 6], total: 11))
            }
        ])
        let events = BoneAgentEventRecorder()
        let agent = try Self.agent(engine: engine, store: store, events: events)
        let run = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "汇总输入并给出正确总数。")])
        let recorded = await events.events()
        XCTAssertEqual(recorded.last, .runFinished(.succeeded), "Run finish alone is not task acceptance")
        let checked = try await BoneInferenceValidatedOutputProcessor<BoneAgentRunOutput, Delivery, [Int]>()
            .process(run.output, policy: .init(maximumCorrectionAttempts: 1),
                validate: { try Self.check($0, records: [4, 6], total: 10) },
                correct: { _, _, _ in
                    let response = try await engine.infer(request: .init(modelID: "task-fixture",
                        messages: [.init(role: .user, content: "Correct total using the original source values 4 and 6.")]))
                    guard case .structured(let value) = response else { throw TaskFixtureError.invalidResult }
                    return .structured(value.data)
                })
        guard case .rejected(let rejection) = checked.validation else { return XCTFail("Wrong answer must not be accepted") }
        XCTAssertEqual(rejection.issue, .contractMismatch)
        XCTAssertEqual(checked.receipt.validationCount, 2)
        XCTAssertEqual(checked.receipt.correctionAttemptCount, 1)
        let requests = await engine.requests()
        XCTAssertEqual(requests.count, 3, "No repeated correction loop")
        let actions = await store.actions()
        XCTAssertEqual(actions, ["read:input"])
    }

    func testInvalidToolArgumentsCannotExecuteOrClaimCompletion() async throws {
        let store = TaskFixtureStore(series: [:])
        let engine = TaskDrivenEngine(steps: [
            { _ in try Self.calls([.init(id: "invalid", toolID: SumSeriesTool.definition.id,
                arguments: Data(#"{"values":["not-an-integer"]}"#.utf8))]) }
        ])
        let events = BoneAgentEventRecorder()
        let agent = try Self.agent(engine: engine, store: store, events: events)
        do {
            _ = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "计算数据合计。")])
            XCTFail("Invalid parameters must stop before execution")
        } catch { XCTAssertEqual(error as? BoneAgentError, .toolArgumentsInvalid) }
        let actions = await store.actions()
        XCTAssertEqual(actions, [])
        let requests = await engine.requests()
        XCTAssertEqual(requests.count, 1)
        let recorded = await events.events()
        XCTAssertFalse(recorded.contains(.runFinished(.succeeded)))
    }

    func testUnauthorizedWriteNeverRuns() async throws {
        let store = TaskFixtureStore(series: [:])
        let engine = TaskDrivenEngine(steps: [
            { _ in try Self.calls([Self.call(UnauthorizedWriteTool.definition.id, id: "write", input: ReadKey(key: "output"))]) }
        ])
        let events = BoneAgentEventRecorder()
        let agent = BoneAgent(inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(UnauthorizedWriteTool(store: store))]),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 2),
            eventSink: events.eventSink())
        do {
            _ = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "只分析，不允许写入。")])
            XCTFail("No write authorization was configured")
        } catch { XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed) }
        let actions = await store.actions()
        XCTAssertEqual(actions, [], "Actual write implementation must never be entered")
        let recorded = await events.events()
        XCTAssertFalse(recorded.contains(.runFinished(.succeeded)))
    }

    func testRepeatedToolCallsStopAtBudgetWithoutFalseSuccess() async throws {
        let store = TaskFixtureStore(series: ["input": [1]])
        let engine = TaskDrivenEngine(steps: (1...5).map { index in
            { @Sendable _ in try Self.calls([Self.readCall("input", id: "read-\(index)")]) }
        })
        let events = BoneAgentEventRecorder()
        let agent = try Self.agent(engine: engine, store: store, events: events,
            budget: Self.budget(inferences: 5, tools: 2))
        do {
            _ = try await agent.run(modelID: "task-fixture", messages: [.init(role: .user, content: "读取一次后交付，不要重复读取。")])
            XCTFail("Loop must hit tool budget")
        } catch { XCTAssertEqual(error as? BoneAgentError, .budgetExceeded) }
        let actions = await store.actions()
        XCTAssertEqual(actions, ["read:input", "read:input"])
        let requests = await engine.requests()
        XCTAssertEqual(requests.count, 3)
        let recorded = await events.events()
        XCTAssertEqual(recorded.last, .runFinished(.failed(.budgetExceeded)))
        XCTAssertFalse(recorded.contains(.runFinished(.succeeded)))
    }

    private static func agent(engine: TaskDrivenEngine, store: TaskFixtureStore,
                              events: BoneAgentEventRecorder = .init(), parallel: Bool = false,
                              failureStrategy: BoneToolFailureStrategy = .failFast,
                              budget: BoneRunBudget? = nil) throws -> BoneAgent {
        BoneAgent(inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(ReadSeriesTool(store: store)), BoneAnyAgentTool(SumSeriesTool(store: store))]),
            toolContext: BoneAgentEmptyContext(), configuration: try .init(maximumSteps: 5,
                toolSchedulingMode: parallel ? .boundedParallel(maximumConcurrency: 2) : .serial,
                toolFailureStrategy: failureStrategy, runBudget: budget,
                inferenceCostEstimator: { _ in 1 }), eventSink: events.eventSink())
    }

    private static func budget(inferences: Int, tools: Int) throws -> BoneRunBudget {
        try .init(maximumInferenceCalls: inferences, maximumToolCalls: tools,
            maximumInputBytes: 100_000, maximumOutputBytes: 100_000, maximumTurns: inferences,
            maximumWallClockSeconds: 60, maximumConcurrentToolCalls: 2, maximumEstimatedCostMicrounits: 100)
    }

    private static func mergeSteps(omitLast: Bool) -> [TaskDrivenEngine.Step] {
        [
            { _ in try calls([readCall("left", id: "left"), readCall("right", id: "right", ordinal: 1)]) },
            { request in
                let left: Series = try toolValue(request, callID: "left")
                let right: Series = try toolValue(request, callID: "right")
                var records = Array(Set(left.values + right.values)).sorted()
                if omitLast { records = Array(records.dropLast()) }
                return try final(Delivery(records: records, total: records.reduce(0, +)))
            }
        ]
    }

    private static func validate(_ output: BoneAgentRunOutput, records: [Int], total: Int) async throws
        -> BoneInferenceOutputProcessingResult<Delivery, [Int]> {
        try await BoneInferenceValidatedOutputProcessor<BoneAgentRunOutput, Delivery, [Int]>()
            .process(output) { try check($0, records: records, total: total) }
    }

    private static func check(_ output: BoneAgentRunOutput, records: [Int], total: Int) throws
        -> BoneInferenceOutputValidation<Delivery, [Int]> {
        let report = try decode(output)
        let missing = Set(records).subtracting(report.records).sorted()
        if !missing.isEmpty {
            return .rejected(try .init(issue: .missingRequiredOutput, issueCount: missing.count,
                allowsCorrection: true, feedback: missing))
        }
        guard report.records == records, report.total == total, report.complete, report.missingSources.isEmpty else {
            return .rejected(try .init(issue: .contractMismatch, allowsCorrection: true))
        }
        return .accepted(report)
    }

    private static func decode(_ output: BoneAgentRunOutput) throws -> Delivery {
        guard case .structured(let data) = output else { throw TaskFixtureError.invalidResult }
        return try JSONDecoder().decode(Delivery.self, from: data)
    }

    private static func toolResults(_ request: BoneInferenceRequest) -> [BoneInferenceToolResult] {
        request.messages.flatMap { message in
            if let batch = message.toolResults { return batch.results }
            if let result = message.toolResult { return [result] }
            return []
        }
    }

    private static func toolValue<T: Decodable>(_ request: BoneInferenceRequest, callID: String) throws -> T {
        let result = try XCTUnwrap(toolResults(request).first { $0.callID == callID })
        guard !result.isError, case .json(let data) = result.content else { throw TaskFixtureError.invalidResult }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func readCall(_ key: String, id: String, ordinal: Int = 0) throws -> BoneInferenceToolCall {
        try call(ReadSeriesTool.definition.id, id: id, input: ReadKey(key: key), ordinal: ordinal)
    }

    private static func call<T: Encodable>(_ tool: String, id: String, input: T, ordinal: Int = 0) throws -> BoneInferenceToolCall {
        .init(id: id, toolID: tool, arguments: try JSONEncoder().encode(input), ordinal: ordinal)
    }

    private static func calls(_ calls: [BoneInferenceToolCall]) throws -> BoneInferenceResponse {
        .assistantTurn(turn: try .init(content: calls.map { .toolCall($0) }), finishReason: .toolCalls,
            usage: nil, refusal: nil, providerContinuation: nil)
    }

    private static func final(_ report: Delivery) throws -> BoneInferenceResponse {
        .structured(.init(data: try JSONEncoder().encode(report)))
    }
}

private struct ReadKey: Codable, Sendable { let key: String }
private struct Series: Codable, Sendable { let values: [Int] }
private struct Total: Codable, Sendable { let value: Int }
private struct Delivery: Codable, Equatable, Sendable {
    let records: [Int]
    let total: Int
    var missingSources: [String] = []
    var complete: Bool = true
}
private struct RepairInput: Codable, Sendable {
    let sourceRecords: [Int]
    let missingRecords: [Int]
}
private enum TaskFixtureError: Error { case sourceUnavailable, invalidResult, scriptExhausted }

private actor TaskFixtureStore {
    private let series: [String: [Int]]
    private var trace: [String] = []
    init(series: [String: [Int]]) { self.series = series }
    func read(_ key: String) throws -> Series {
        trace.append("read:" + key)
        guard let values = series[key] else { throw TaskFixtureError.sourceUnavailable }
        return .init(values: values)
    }
    func sum(_ values: [Int]) -> Total {
        trace.append("sum:\(values.count)")
        return .init(value: values.reduce(0, +))
    }
    func write(_ key: String) -> Total {
        trace.append("write:" + key)
        return .init(value: 1)
    }
    func actions() -> [String] { trace }
}

private struct ReadSeriesTool: BoneAgentTool {
    typealias Input = ReadKey
    typealias Output = Series
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(id: "fixture.read", version: "1", title: "读取合成数据",
        summary: "读取指定 fixture 来源的数字数组", wireName: "fixture_read", schemaVersion: 1,
        inputSchema: .object(properties: ["key": .string(enumValues: [], minimumLength: 1, maximumLength: 32)],
            required: ["key"], additionalProperties: false),
        executionPolicy: .parallelSafe(resourceKeys: []), impact: .ordinaryPublicRead)
    let store: TaskFixtureStore
    func execute(input: ReadKey, context: Context) async throws -> Series { try await store.read(input.key) }
}

private struct SumSeriesTool: BoneAgentTool {
    typealias Input = Series
    typealias Output = Total
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(id: "fixture.sum", version: "1", title: "合计",
        summary: "计算有界整数数组总和", wireName: "fixture_sum", schemaVersion: 1,
        inputSchema: .object(properties: ["values": .array(items: .integer(minimum: 0, maximum: 10_000),
            minimumItems: 0, maximumItems: 100)], required: ["values"], additionalProperties: false),
        impact: .ordinaryPublicRead)
    let store: TaskFixtureStore
    func execute(input: Series, context: Context) async throws -> Total { await store.sum(input.values) }
}

private struct UnauthorizedWriteTool: BoneAgentTool {
    typealias Input = ReadKey
    typealias Output = Total
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(id: "fixture.write", version: "1", title: "模拟写入",
        summary: "此工具必须通过授权与副作用管线", wireName: "fixture_write", schemaVersion: 1,
        inputSchema: .object(properties: ["key": .string(enumValues: [], minimumLength: 1, maximumLength: 32)],
            required: ["key"], additionalProperties: false),
        impact: .init(dataAccess: .public, externalTransmission: .none, stateChange: .irreversible,
            economic: .none, userVisible: .none, permissionChange: .none))
    let store: TaskFixtureStore
    func execute(input: ReadKey, context: Context) async throws -> Total { await store.write(input.key) }
}

/// 只替代模型决策；每个后续步骤须读取 Agent 真正传来的工具结果。
private actor TaskDrivenEngine: BoneInferenceEngine {
    typealias Step = @Sendable (BoneInferenceRequest) throws -> BoneInferenceResponse
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .structuredOutput]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    private let steps: [Step]
    private var received: [BoneInferenceRequest] = []
    init(steps: [Step]) { self.steps = steps }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let index = received.count
        received.append(request)
        guard steps.indices.contains(index) else { throw TaskFixtureError.scriptExhausted }
        return try steps[index](request)
    }
    func requests() -> [BoneInferenceRequest] { received }
}
