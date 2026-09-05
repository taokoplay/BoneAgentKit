import Foundation
import XCTest
import BoneAgentTesting
@testable import BoneAgentKit

private enum RecoveryFault: Error { case injected, invariant }
private enum RecoveryCut: Sendable, CaseIterable {
    case beforeIntent, afterIntent, afterExecutionStarted, afterExternalWrite, beforeReceipt, afterReceipt, afterCommit, none
}

/// Deliberately in-memory Host seam. Mutations validate identities and fencing, not a scripted event list.
/// A thrown post-mutation error simulates loss of acknowledgement; it is NOT a real process crash.
private actor RecoveryStore: BoneWorkflowEffectStore {
    let cut: RecoveryCut
    private var intent: BoneEffectIntent?
    private var receipt: BoneEffectReceipt?
    private var consumed = false
    private var cancelled = false
    private var committed = false
    private var checkpoint: BoneEffectReceipt?
    private var generation: UInt64 = 1
    private var unknown = false
    private var externalWrites = 0
    private var queries = 0
    private var events = 0
    private var grant: BoneAuthorizationGrant

    init(cut: RecoveryCut, grant: BoneAuthorizationGrant) { self.cut = cut; self.grant = grant }
    func takeover() { generation += 1 }
    func facts() -> (writes: Int, queries: Int, events: Int, consumed: Bool, unknown: Bool, checkpoint: BoneEffectReceipt?) {
        (externalWrites, queries, events, consumed, unknown, checkpoint)
    }
    private func fence(_ lease: UInt64) throws { guard lease == generation else { throw RecoveryFault.invariant } }
    private func execution(_ id: BoneEffectID, _ lease: UInt64) throws -> BoneEffectIntent {
        guard let intent, intent.id == id, intent.leaseGeneration == lease else { throw RecoveryFault.invariant }
        return intent
    }
    private func copy(_ old: BoneEffectIntent, phase: BoneEffectPhase, lease: UInt64) throws -> BoneEffectIntent {
        try .init(id: old.id, runID: old.runID, stepID: old.stepID, attemptID: old.attemptID, toolCallID: old.toolCallID,
            recoveryStrategy: old.recoveryStrategy, idempotencyKey: old.idempotencyKey, argumentsDigest: old.argumentsDigest, phase: phase, leaseGeneration: lease)
    }
    func consumeAuthorizationAndPersistIntent(_ validation: BoneAuthorizationValidation, intent next: BoneEffectIntent) throws {
        try fence(next.leaseGeneration)
        guard !consumed, intent == nil, validation.ticketID == grant.ticketID,
              validation.canonicalCall == grant.canonicalCall, validation.runID == grant.runID,
              validation.stepID == grant.stepID, validation.attemptID == grant.attemptID,
              validation.toolCallID == grant.toolCallID, validation.principal == grant.principal,
              validation.resourceScope == grant.resourceScope, validation.resourceRevision == grant.resourceRevision,
              validation.impact == grant.impact, validation.nonce == grant.nonce,
              validation.nowUptime >= grant.grantedAtUptime, validation.nowUptime <= grant.expiresAtUptime,
              next.argumentsDigest == validation.canonicalCall.argumentsDigest else { throw BoneAuthorizationError.bindingMismatch }
        if cut == .beforeIntent { throw RecoveryFault.injected }
        consumed = true
        intent = next
        if cut == .afterIntent { throw RecoveryFault.injected }
    }
    func persistCancellation(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        try fence(leaseGeneration)
        let old = try execution(effectID, leaseGeneration)
        guard old.phase == .intentPersisted else { throw RecoveryFault.invariant }
        cancelled = true
    }
    func markExecutionStarted(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        try fence(leaseGeneration)
        let old = try execution(effectID, leaseGeneration)
        guard old.phase == .intentPersisted, !cancelled else { throw RecoveryFault.invariant }
        intent = try copy(old, phase: .executionStarted, lease: leaseGeneration)
        if cut == .afterExecutionStarted { throw RecoveryFault.injected }
    }
    func performExternalWrite() throws -> Data {
        guard intent?.phase == .executionStarted else { throw RecoveryFault.invariant }
        externalWrites += 1
        if cut == .afterExternalWrite { throw RecoveryFault.injected }
        return Data("result".utf8)
    }
    func recordReceipt(_ next: BoneEffectReceipt) throws {
        try fence(next.leaseGeneration)
        let old = try execution(next.effectID, next.leaseGeneration)
        guard old.phase == .executionStarted, receipt == nil else { throw RecoveryFault.invariant }
        if cut == .beforeReceipt { throw RecoveryFault.injected }
        receipt = next
        if cut == .afterReceipt { throw RecoveryFault.injected }
    }
    func commitReceipt(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        try fence(leaseGeneration)
        _ = try execution(effectID, leaseGeneration)
        guard let receipt, receipt.effectID == effectID, receipt.leaseGeneration == leaseGeneration else { throw RecoveryFault.invariant }
        checkpoint = receipt
        committed = true
        if cut == .afterCommit { throw RecoveryFault.injected }
    }
    func observe(effectID: BoneEffectID, outcome: BoneEffectOutcome) {
        XCTAssertTrue(committed)
        XCTAssertEqual(checkpoint?.effectID, effectID)
        XCTAssertEqual(checkpoint?.outcome, outcome)
        events += 1
    }
    func recoverySnapshot(effectID: BoneEffectID, currentLeaseGeneration: UInt64) throws -> BoneEffectRecoverySnapshot? {
        try fence(currentLeaseGeneration)
        guard let intent else { return nil }
        guard intent.id == effectID else { throw RecoveryFault.invariant }
        return .init(intent: intent, receipt: receipt, stepCommitted: committed, cancellationPersisted: cancelled)
    }
    func persistOutcomeUnknown(effectID: BoneEffectID, currentLeaseGeneration: UInt64) throws {
        try fence(currentLeaseGeneration)
        guard intent?.id == effectID, intent?.phase == .executionStarted, receipt == nil else { throw RecoveryFault.invariant }
        unknown = true
    }
    func resumePreparedEffect(effectID: BoneEffectID, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        try fence(currentLeaseGeneration)
        let old = try execution(effectID, expectedExecutionLeaseGeneration)
        guard old.phase == .intentPersisted, receipt == nil, !cancelled else { throw RecoveryFault.invariant }
        intent = try copy(old, phase: old.phase, lease: currentLeaseGeneration)
    }
    func commitRecoveredReceipt(effectID: BoneEffectID, receiptLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        try fence(currentLeaseGeneration)
        _ = try execution(effectID, receiptLeaseGeneration)
        guard let receipt, receipt.effectID == effectID, receipt.leaseGeneration == receiptLeaseGeneration else { throw RecoveryFault.invariant }
        checkpoint = receipt
        committed = true
    }
    func queryExternalOutcome() throws -> BoneEffectReceipt {
        guard let intent, intent.phase == .executionStarted, externalWrites == 1 else { throw RecoveryFault.invariant }
        queries += 1
        return try .init(effectID: intent.id, outcome: .reconciledSucceeded, resultDigest: BoneSHA256.hexDigest(Data("result".utf8)), leaseGeneration: intent.leaseGeneration)
    }
    func recordRecoveredReceipt(_ next: BoneEffectReceipt, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        try fence(currentLeaseGeneration)
        _ = try execution(next.effectID, expectedExecutionLeaseGeneration)
        guard queries > 0, next.leaseGeneration == expectedExecutionLeaseGeneration, receipt == nil else { throw RecoveryFault.invariant }
        receipt = next
    }
}

final class WorkflowRecoveryTests: XCTestCase {
    private static let definition = BoneAgentToolDefinition(id: "write", version: "1", title: "Write", summary: "In-memory recovery contract", wireName: "write", schemaVersion: 1,
        inputSchema: .object(properties: [:], required: [], additionalProperties: false),
        impact: .init(dataAccess: .public, externalTransmission: .none, stateChange: .irreversible, economic: .none, userVisible: .none, permissionChange: .none))

    private static func setup(_ cut: RecoveryCut, strategy: BoneEffectRecoveryStrategy = .nonRecoverableRequiresUserDecision) throws -> (RecoveryStore, BoneWorkflowToolExecutionContext) {
        let context = try BoneWorkflowToolExecutionContext(ticketID: .init("ticket"), runID: .init("run"), stepID: .init("step"), attemptID: .init("attempt"), toolCallID: .init("call"), effectID: .init("effect"),
            principal: "host", resourceScope: "fixture", resourceRevision: 1, authorizationNonce: "nonce", nowUptime: 15, leaseGeneration: 1,
            recoveryStrategy: strategy, idempotencyKey: strategy == .idempotencyKeyRequired ? "stable-key" : nil)
        let grant = try BoneAuthorizationGrant(ticketID: context.ticketID, runID: context.runID, stepID: context.stepID, attemptID: context.attemptID, toolCallID: context.toolCallID,
            canonicalCall: .init(toolID: definition.id, toolVersion: definition.version, schemaVersion: 1, arguments: Data("{}".utf8)),
            principal: context.principal, resourceScope: context.resourceScope, resourceRevision: context.resourceRevision, impact: definition.impact!, grantedAtUptime: 10, expiresAtUptime: 20, nonce: context.authorizationNonce)
        return (RecoveryStore(cut: cut, grant: grant), context)
    }
    private static func pipeline(_ store: RecoveryStore) -> BoneWorkflowToolExecutionPipeline {
        .init(effectStore: store, commitObserver: .init { await store.observe(effectID: $0, outcome: $1) })
    }
    private static func execute(_ store: RecoveryStore, _ context: BoneWorkflowToolExecutionContext) async -> BoneWorkflowToolExecutionError? {
        do {
            _ = try await pipeline(store).execute(arguments: Data("{}".utf8), definition: definition, context: context) { try await store.performExternalWrite() }
            return nil
        } catch { return error as? BoneWorkflowToolExecutionError ?? .invalidContext }
    }

    func testExecutionCrashMatrixUsesPersistedFactsNotObserverEvents() async throws {
        for cut in RecoveryCut.allCases {
            let (store, context) = try Self.setup(cut)
            let error = await Self.execute(store, context)
            let expectedError: BoneWorkflowToolExecutionError?
            switch cut {
            case .beforeIntent, .afterIntent, .afterExecutionStarted: expectedError = .effectStoreRejected
            case .afterExternalWrite: expectedError = .outcomeUnknown
            case .beforeReceipt, .afterReceipt, .afterCommit: expectedError = .recoveryRequired
            case .none: expectedError = nil
            }
            XCTAssertEqual(error, expectedError, "\(cut)")
            let snapshot = try await store.recoverySnapshot(effectID: context.effectID, currentLeaseGeneration: 1)
            let facts = await store.facts()
            XCTAssertEqual(facts.writes, [.beforeIntent, .afterIntent, .afterExecutionStarted].contains(cut) ? 0 : 1, "\(cut)")
            XCTAssertEqual(facts.consumed, cut != .beforeIntent)
            XCTAssertEqual(facts.events, cut == .none ? 1 : 0)
            XCTAssertEqual(facts.checkpoint != nil, cut == .afterCommit || cut == .none)
            if cut == .beforeIntent {
                XCTAssertNil(snapshot)
                continue
            }
            let saved = try XCTUnwrap(snapshot)
            XCTAssertEqual(saved.intent.id, context.effectID)
            XCTAssertEqual(saved.intent.phase, cut == .afterIntent ? .intentPersisted : .executionStarted)
            XCTAssertEqual(saved.receipt != nil, [.afterReceipt, .afterCommit, .none].contains(cut))
            let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 1)
            switch cut {
            case .afterIntent: XCTAssertEqual(action, .execute)
            case .afterReceipt: XCTAssertEqual(action, .commitReceipt)
            case .afterCommit, .none: XCTAssertEqual(action, .completed)
            default:
                XCTAssertEqual(action, .recoveryRequired(.outcomeUnknown))
                let recovered = await store.facts()
                XCTAssertTrue(recovered.unknown)
            }
            let after = await store.facts()
            XCTAssertEqual(after.writes, facts.writes, "Recovery must never blindly execute")
        }
    }

    func testCrashHarnessCommitWindowsRecoverWithoutReexecutionOrEventAssumption() async throws {
        _ = try await BoneCrashBoundaryHarness().run { boundary in
            let cut: RecoveryCut = boundary == .beforePersistenceCommit ? .afterReceipt : boundary == .afterPersistenceCommitBeforeEvent ? .afterCommit : .none
            let (store, context) = try Self.setup(cut)
            _ = await Self.execute(store, context)
            let before = await store.facts()
            XCTAssertEqual(before.checkpoint != nil, boundary != .beforePersistenceCommit)
            XCTAssertEqual(before.events, boundary == .afterEventBeforeNextWork ? 1 : 0)
            await store.takeover()
            // A new pipeline has no knowledge of observer delivery; only persisted facts matter.
            for _ in 0..<2 {
                let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
                XCTAssertEqual(action, .completed)
            }
            let after = await store.facts()
            XCTAssertEqual(after.writes, 1)
            XCTAssertNotNil(after.checkpoint)
            XCTAssertEqual(after.events, before.events, "Recovery does not promise exactly-once event delivery")
            return "reloaded checkpoint and receipt"
        }
    }

    func testPreparedIntentTakeoverPreservesIdentityAndFencesOldWorker() async throws {
        let (store, context) = try Self.setup(.afterIntent)
        _ = await Self.execute(store, context)
        await store.takeover()
        let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
        XCTAssertEqual(action, .execute)
        let value = try await store.recoverySnapshot(effectID: context.effectID, currentLeaseGeneration: 2)
        let saved = try XCTUnwrap(value)
        XCTAssertEqual(saved.intent.leaseGeneration, 2)
        XCTAssertEqual(saved.intent.id, context.effectID)
        XCTAssertEqual(saved.intent.attemptID, context.attemptID)
        do { try await store.markExecutionStarted(effectID: context.effectID, leaseGeneration: 1); XCTFail("Old execution allowed") }
        catch { XCTAssertTrue(error is RecoveryFault) }
        do { _ = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 1); XCTFail("Stale recovery allowed") }
        catch { XCTAssertEqual(error as? BoneWorkflowToolExecutionError, .effectStoreRejected) }
        let facts = await store.facts()
        XCTAssertEqual(facts.writes, 0)
        XCTAssertTrue(facts.consumed)
    }

    func testReconcileQueriesBeforeReceiptAndNeverRepeatsExternalWrite() async throws {
        for strategy: BoneEffectRecoveryStrategy in [.reconcilable, .compensatable] {
            let (store, context) = try Self.setup(.afterExternalWrite, strategy: strategy)
            _ = await Self.execute(store, context)
            await store.takeover()
            let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
            XCTAssertEqual(action, strategy == .reconcilable ? .reconcile : .reconcileBeforeCompensation)
            let before = await store.facts()
            XCTAssertEqual(before.queries, 0, "SDK returns a decision; Host owns the query")
            XCTAssertNil(before.checkpoint)
            let receipt = try await store.queryExternalOutcome()
            try await store.recordRecoveredReceipt(receipt, expectedExecutionLeaseGeneration: 1, currentLeaseGeneration: 2)
            let completed = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
            XCTAssertEqual(completed, .completed)
            let facts = await store.facts()
            XCTAssertEqual(facts.writes, 1)
            XCTAssertEqual(facts.queries, 1)
            XCTAssertEqual(facts.checkpoint?.outcome, .reconciledSucceeded)
            XCTAssertEqual(facts.checkpoint?.leaseGeneration, 1)
        }
    }

    func testCancelledPreparedIntentIsNotTakenOverOrExecuted() async throws {
        let (store, context) = try Self.setup(.afterIntent)
        _ = await Self.execute(store, context)
        try await store.persistCancellation(effectID: context.effectID, leaseGeneration: 1)
        await store.takeover()
        let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
        XCTAssertEqual(action, .cancelWithoutExecution)
        let snapshot = try await store.recoverySnapshot(effectID: context.effectID, currentLeaseGeneration: 2)
        XCTAssertEqual(snapshot?.intent.leaseGeneration, 1)
        let facts = await store.facts()
        XCTAssertEqual(facts.writes, 0)
        XCTAssertNil(facts.checkpoint)
    }

    func testMismatchedReceiptCannotBecomeCommitDecision() async throws {
        let (store, context) = try Self.setup(.afterReceipt)
        _ = await Self.execute(store, context)
        let value = try await store.recoverySnapshot(effectID: context.effectID, currentLeaseGeneration: 1)
        let snapshot = try XCTUnwrap(value)
        for wrongIdentity in [false, true] {
            let receipt = try BoneEffectReceipt(effectID: wrongIdentity ? .init("other") : context.effectID,
                outcome: .succeeded, resultDigest: String(repeating: "a", count: 64), leaseGeneration: wrongIdentity ? 1 : 2)
            let action = BoneWorkflowRecoveryPlanner().plan(.init(intent: snapshot.intent, receipt: receipt, stepCommitted: false, cancellationPersisted: false))
            XCTAssertEqual(action, .recoveryRequired(wrongIdentity ? .receiptMismatch : .fencingConflict))
        }
    }

    func testIdempotencyDeclarationCannotProveOutcomeOrAuthorizeRetry() async throws {
        for strategy: BoneEffectRecoveryStrategy in [.naturallyIdempotent, .idempotencyKeyRequired, .nonRecoverableRequiresUserDecision] {
            let (store, context) = try Self.setup(.afterExternalWrite, strategy: strategy)
            _ = await Self.execute(store, context)
            await store.takeover()
            for _ in 0..<2 {
                let action = try await Self.pipeline(store).recoveryAction(effectID: context.effectID, currentLeaseGeneration: 2)
                XCTAssertEqual(action, .recoveryRequired(.outcomeUnknown))
            }
            let facts = await store.facts()
            XCTAssertTrue(facts.unknown)
            XCTAssertEqual(facts.writes, 1)
            XCTAssertEqual(facts.queries, 0)
            XCTAssertNil(facts.checkpoint)
        }
    }
}
