import Foundation
import XCTest
@testable import BoneAgentKit

private enum EffectFault: Error { case injected }
private enum EffectMode: Sendable {
    case throwsAfterWrite, cancelAfterWrite, cancelThenReturn, rejectAuthorization, cancelBeforeExecution
    case rejectReceipt, rejectCommit, succeed
}

private actor EffectFixture: BoneWorkflowEffectStore {
    let mode: EffectMode
    var intents: [BoneEffectID: BoneEffectIntent] = [:]
    var receipt: BoneEffectReceipt?
    var committed = false
    var cancelled = false
    var writes = 0
    var events: [BoneAgentEvent] = []
    init(_ mode: EffectMode) { self.mode = mode }
    func observe(_ event: BoneAgentEvent) { events.append(event) }
    func execute() throws {
        writes += 1
        switch mode {
        case .throwsAfterWrite: throw EffectFault.injected
        case .cancelAfterWrite:
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        case .cancelThenReturn: withUnsafeCurrentTask { $0?.cancel() }
        default: break
        }
    }
    func consumeAuthorizationAndPersistIntent(_ validation: BoneAuthorizationValidation, intent: BoneEffectIntent) throws {
        if mode == .rejectAuthorization { throw BoneAuthorizationError.denied }
        guard intents[intent.id] == nil else { throw EffectFault.injected }
        intents[intent.id] = intent
        if mode == .cancelBeforeExecution { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func persistCancellation(effectID: BoneEffectID, leaseGeneration: UInt64) { cancelled = true }
    func markExecutionStarted(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        guard let old = intents[effectID], old.id == effectID, old.phase == .intentPersisted else { throw EffectFault.injected }
        intents[effectID] = try .init(id: old.id, runID: old.runID, stepID: old.stepID, attemptID: old.attemptID,
                           toolCallID: old.toolCallID, recoveryStrategy: old.recoveryStrategy,
                           idempotencyKey: old.idempotencyKey, argumentsDigest: old.argumentsDigest,
                           phase: .executionStarted, leaseGeneration: leaseGeneration)
    }
    func recordReceipt(_ receipt: BoneEffectReceipt) throws {
        if mode == .rejectReceipt { throw EffectFault.injected }
        guard intents[receipt.effectID]?.phase == .executionStarted else { throw EffectFault.injected }
        self.receipt = receipt
    }
    func commitReceipt(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        if mode == .rejectCommit { throw EffectFault.injected }
        guard receipt?.effectID == effectID else { throw EffectFault.injected }
        committed = true
    }
    func recoverySnapshot(effectID: BoneEffectID, currentLeaseGeneration: UInt64) -> BoneEffectRecoverySnapshot? {
        guard let intent = intents[effectID] else { return nil }
        return .init(intent: intent, receipt: receipt, stepCommitted: committed, cancellationPersisted: cancelled)
    }
    func persistOutcomeUnknown(effectID: BoneEffectID, currentLeaseGeneration: UInt64) {}
    func resumePreparedEffect(effectID: BoneEffectID, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws { throw EffectFault.injected }
    func commitRecoveredReceipt(effectID: BoneEffectID, receiptLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws { throw EffectFault.injected }
    func recordRecoveredReceipt(_ receipt: BoneEffectReceipt, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws { throw EffectFault.injected }
    func observations() -> (Int, [BoneAgentEvent]) { (writes, events) }
}

private struct EffectWriteTool: BoneAgentTool {
    struct Payload: Codable, Sendable {}
    typealias Input = Payload
    typealias Output = Payload
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(
        id: "effect-write", version: "1", title: "Write", summary: "In-memory write",
        wireName: "effect_write", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false),
        impact: .init(dataAccess: .public, externalTransmission: .none, stateChange: .irreversible,
                      economic: .none, userVisible: .none, permissionChange: .none))
    let fixture: EffectFixture
    func execute(input: Input, context: Context) async throws -> Output {
        try await fixture.execute()
        return .init()
    }
}

private struct EffectReadTool: BoneAgentTool {
    typealias Input = EffectWriteTool.Payload
    typealias Output = EffectWriteTool.Payload
    typealias Context = BoneAgentEmptyContext
    static let definition = BoneAgentToolDefinition(
        id: "effect-read", version: "1", title: "Read", summary: "Failing local read",
        wireName: "effect_read", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false), impact: .ordinaryPublicRead)
    func execute(input: Input, context: Context) async throws -> Output { throw EffectFault.injected }
}

private actor EffectEngine: BoneInferenceEngine {
    nonisolated let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling]
    nonisolated let imageGenerator: (any BoneInferenceImageGenerating)? = nil
    let first: BoneInferenceResponse
    var count = 0
    init(legacy: Bool, readOnly: Bool) throws {
        let id = readOnly ? EffectReadTool.definition.id : EffectWriteTool.definition.id
        let a = BoneInferenceToolCall(id: "a", toolID: id, arguments: Data("{}".utf8), ordinal: 0)
        let b = BoneInferenceToolCall(id: "b", toolID: id, arguments: Data("{}".utf8), ordinal: 1)
        first = legacy ? .toolCall(a) : .assistantTurn(
            turn: try .init(content: [.toolCall(a), .toolCall(b)]), finishReason: .toolCalls,
            usage: nil, refusal: nil, providerContinuation: nil)
    }
    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        count += 1
        return count == 1 ? first : .finish(.init(text: "done"))
    }
    func calls() -> Int { count }
}

final class WorkflowEffectExecutionTests: XCTestCase {
    private static func makeContext(_ call: BoneInferenceToolCall, strategy: BoneEffectRecoveryStrategy = .reconcilable) throws -> BoneWorkflowToolExecutionContext {
        try .init(ticketID: .init("ticket"), runID: .init("run"), stepID: .init("step"), attemptID: .init("attempt"),
                  toolCallID: .init(call.id), effectID: .init(call.id), principal: "host", resourceScope: "fixture",
                  resourceRevision: 1, authorizationNonce: "nonce", nowUptime: 1, leaseGeneration: 1,
                  recoveryStrategy: strategy, idempotencyKey: nil)
    }
    private func run(_ mode: EffectMode, legacy: Bool = false, readOnly: Bool = false) async throws -> (Error?, EffectFixture, EffectEngine) {
        let fixture = EffectFixture(mode)
        let engine = try EffectEngine(legacy: legacy, readOnly: readOnly)
        let agent = BoneAgent(inferenceEngine: engine,
            toolRegistry: try .init(tools: [BoneAnyAgentTool(EffectWriteTool(fixture: fixture)), BoneAnyAgentTool(EffectReadTool())]),
            toolContext: BoneAgentEmptyContext(),
            configuration: try .init(maximumSteps: 3, toolFailureStrategy: .collectAll,
                toolImpactPolicy: .init(maximumAllowed: EffectWriteTool.definition.impact!),
                toolExecutionPipeline: .init(effectStore: fixture),
                toolExecutionContextProvider: { call, _ in try Self.makeContext(call) }),
            eventSink: .init { await fixture.observe($0) })
        let task = Task { () -> Error? in
            do { _ = try await agent.run(modelID: "fixture", messages: [.init(role: .user, content: "test")]); return nil }
            catch { return error }
        }
        return await (task.value, fixture, engine)
    }

    func testUnknownWriteStopsBatchAndNextInference() async throws {
        let (error, fixture, engine) = try await run(.throwsAfterWrite)
        XCTAssertEqual(error as? BoneAgentError, .toolOutcomeUnknown)
        let count = await engine.calls()
        let observed = await fixture.observations()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(observed.0, 1)
        XCTAssertFalse(observed.1.contains(.runFinished(.succeeded)))
        let snapshot = await fixture.recoverySnapshot(effectID: try .init("a"), currentLeaseGeneration: 1)
        XCTAssertEqual(snapshot?.intent.phase, .executionStarted)
        XCTAssertNil(snapshot?.receipt)
        let action = try await BoneWorkflowToolExecutionPipeline(effectStore: fixture).recoveryAction(effectID: .init("a"), currentLeaseGeneration: 1)
        XCTAssertEqual(action, .reconcile)
    }

    func testLegacyUnknownWritePreservesRecoveryClassification() async throws {
        try await assertStopped(.throwsAfterWrite, expected: .toolOutcomeUnknown, legacy: true)
    }

    func testPostExecutionCancellationIsUnknownNotCancelled() async throws {
        for legacy in [false, true] {
            try await assertStopped(.cancelAfterWrite, expected: .toolOutcomeUnknown, legacy: legacy)
        }
    }

    func testReceiptRecordingFailureRequiresRecoveryWithNoReceipt() async throws {
        for legacy in [false, true] {
            try await assertStopped(.rejectReceipt, expected: .toolRecoveryRequired, legacy: legacy)
        }
    }

    func testReceiptCommitFailureRequiresCommitNotReexecution() async throws {
        for legacy in [false, true] {
            try await assertStopped(.rejectCommit, expected: .toolRecoveryRequired, legacy: legacy)
        }
    }

    private func assertStopped(_ mode: EffectMode, expected: BoneAgentError, legacy: Bool) async throws {
        let (error, fixture, engine) = try await run(mode, legacy: legacy)
        XCTAssertEqual(error as? BoneAgentError, expected)
        let count = await engine.calls()
        let observed = await fixture.observations()
        XCTAssertEqual(count, 1)
        XCTAssertEqual(observed.0, 1)
        XCTAssertEqual(observed.1.last, .runFinished(.failed(expected)))
        let value = await fixture.recoverySnapshot(effectID: try .init("a"), currentLeaseGeneration: 1)
        let snapshot = try XCTUnwrap(value)
        XCTAssertEqual(snapshot.intent.phase, .executionStarted)
        XCTAssertFalse(snapshot.stepCommitted)
        if mode == .rejectCommit {
            XCTAssertNotNil(snapshot.receipt)
            XCTAssertEqual(BoneWorkflowRecoveryPlanner().plan(snapshot), .commitReceipt)
        } else {
            XCTAssertNil(snapshot.receipt)
            XCTAssertEqual(BoneWorkflowRecoveryPlanner().plan(snapshot), .reconcile)
        }
    }

    func testAuthorizationRejectionDoesNotExecuteOrCreateIntent() async throws {
        for legacy in [false, true] {
            let (error, fixture, engine) = try await run(.rejectAuthorization, legacy: legacy)
            XCTAssertEqual(error as? BoneAgentError, .toolExecutionFailed)
            let count = await engine.calls()
            let observed = await fixture.observations()
            let snapshot = await fixture.recoverySnapshot(effectID: try .init("a"), currentLeaseGeneration: 1)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(observed.0, 0)
            XCTAssertNil(snapshot)
        }
    }

    func testPreExecutionCancellationPersistsWithoutExecuting() async throws {
        for legacy in [false, true] {
            let (error, fixture, engine) = try await run(.cancelBeforeExecution, legacy: legacy)
            XCTAssertTrue(error is CancellationError)
            let count = await engine.calls()
            let observed = await fixture.observations()
            let value = await fixture.recoverySnapshot(effectID: try .init("a"), currentLeaseGeneration: 1)
            let snapshot = try XCTUnwrap(value)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(observed.0, 0)
            XCTAssertEqual(snapshot.intent.phase, .intentPersisted)
            XCTAssertTrue(snapshot.cancellationPersisted)
            XCTAssertNil(snapshot.receipt)
            XCTAssertEqual(BoneWorkflowRecoveryPlanner().plan(snapshot), .cancelWithoutExecution)
        }
    }

    func testCancellationWithReturnedOutputStillCommitsReceiptBeforeStopping() async throws {
        for legacy in [false, true] {
            let (error, fixture, engine) = try await run(.cancelThenReturn, legacy: legacy)
            XCTAssertTrue(error is CancellationError)
            let count = await engine.calls()
            let observed = await fixture.observations()
            let value = await fixture.recoverySnapshot(effectID: try .init("a"), currentLeaseGeneration: 1)
            let snapshot = try XCTUnwrap(value)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(observed.0, 1)
            XCTAssertEqual(observed.1.last, .runFinished(.cancelled))
            XCTAssertNotNil(snapshot.receipt)
            XCTAssertTrue(snapshot.stepCommitted)
            XCTAssertEqual(BoneWorkflowRecoveryPlanner().plan(snapshot), .completed)
        }
    }

    func testNonReconcilableUnknownOutcomeRequiresHostDecisionWithoutNewIntent() async throws {
        let fixture = EffectFixture(.throwsAfterWrite)
        let pipeline = BoneWorkflowToolExecutionPipeline(effectStore: fixture)
        let call = BoneInferenceToolCall(id: "a", toolID: EffectWriteTool.definition.id, arguments: Data("{}".utf8))
        let context = try Self.makeContext(call, strategy: .nonRecoverableRequiresUserDecision)
        do {
            _ = try await pipeline.execute(arguments: call.arguments, definition: EffectWriteTool.definition, context: context) {
                try await fixture.execute()
                return Data("{}".utf8)
            }
            XCTFail("Unknown effect must throw")
        } catch let error as BoneWorkflowToolExecutionError {
            XCTAssertEqual(error, .outcomeUnknown)
        }
        let action = try await pipeline.recoveryAction(effectID: context.effectID, currentLeaseGeneration: 1)
        XCTAssertEqual(action, .recoveryRequired(.outcomeUnknown))
        let observed = await fixture.observations()
        XCTAssertEqual(observed.0, 1)
    }

    func testOrdinaryReadFailureStillCollectsAndContinuesInference() async throws {
        let (error, _, engine) = try await run(.succeed, readOnly: true)
        XCTAssertNil(error)
        let count = await engine.calls()
        XCTAssertEqual(count, 2)
    }
}
