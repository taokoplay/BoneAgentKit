import XCTest
import BoneAgentKit

final class WorkflowCancellationReadinessTests: XCTestCase {
    func testUnstartedContinuationCanCloseWithCompleteEvidence() throws {
        let snapshot = try fixture()
        let result = BoneWorkflowCancellationReadiness().evaluate(snapshot)
        XCTAssertEqual(result.decision, .ready)
        XCTAssertEqual(result.runID, snapshot.runID)
        XCTAssertEqual(result.runRevision, 5)
        XCTAssertEqual(result.leaseGeneration, 2)
        XCTAssertEqual(result.evidenceRevision, 9)
    }

    func testUnknownHistoricalEffectAlwaysRejects() throws {
        let snapshot = try fixture(effects: [.init(id: .init("effect"), sessionID: "previous", state: .outcomeUnknown)])
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, .rejected(.unknownEffect))
    }

    func testMissingSessionCannotBeInferredFromAbsentWorker() throws {
        let snapshot = try fixture(session: nil)
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, .rejected(.missingSession))
    }

    func testMissingSessionOrStageCoverageAlwaysRejects() throws {
        for (sessionComplete, stagesComplete) in [(false, true), (true, false), (false, false)] {
            let snapshot = try fixture(sessionComplete: sessionComplete, stagesComplete: stagesComplete)
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, .rejected(.incompleteEvidence))
        }
    }

    func testInvalidSessionIdentityOrRevisionIsNotTrusted() throws {
        for session in [
            BoneWorkflowCancellationSnapshot.Session(id: "", sequence: 1, revision: 1, isActive: true, hasObservation: false),
            .init(id: "current", sequence: 1, revision: 0, isActive: true, hasObservation: false)
        ] {
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(session: session)).decision, .rejected(.invalidEvidence))
        }
    }

    func testCancellationBeforeAndAfterQueryDoesNotYieldReady() async throws {
        for cancelInside in [false, true] {
            let snapshot = try fixture()
            let task = Task {
                if !cancelInside { withUnsafeCurrentTask { $0?.cancel() } }
                return try await BoneWorkflowCancellationReadiness().evaluate(runID: snapshot.runID,
                    query: CancellingQuery(snapshot: snapshot, cancelInside: cancelInside))
            }
            do { _ = try await task.value; XCTFail("Cancelled evaluation cannot return ready") }
            catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        }
    }

    func testNoObservationDoesNotProveCompleteEffectHistory() throws {
        let snapshot = try fixture(effectsComplete: false)
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, .rejected(.incompleteEvidence))
    }

    func testCurrentSessionEffectRejectsEvenWhenCommitted() throws {
        let snapshot = try fixture(effects: [.init(id: .init("effect"), sessionID: "current", state: .committed)])
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, .rejected(.currentSessionHasEffects))
    }

    func testOldCommittedEffectIsAllowedButUncommittedIsNot() throws {
        for state in [BoneWorkflowCancellationSnapshot.Effect.State.committed, .uncommitted] {
            let snapshot = try fixture(effects: [.init(id: .init("effect"), sessionID: "previous", state: state)])
            let expected: BoneWorkflowCancellationDecision = state == .committed ? .ready : .rejected(.uncommittedEffect)
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(snapshot).decision, expected)
        }
    }

    func testStagePreflightAndHostPolicyEachCanVeto() throws {
        for (checks, expected) in [
            (BoneWorkflowCancellationSnapshot.Checks(hasStageActivity: true, preflightPassed: true, hostAllowsClosure: true), BoneWorkflowCancellationRejection.stageActivity),
            (.init(hasStageActivity: false, preflightPassed: false, hostAllowsClosure: true), .preflightRejected),
            (.init(hasStageActivity: false, preflightPassed: true, hostAllowsClosure: false), .hostRejected)
        ] {
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(checks: checks)).decision, .rejected(expected))
        }
    }

    func testNotContinuationInactiveOrObservedSessionRejects() throws {
        for (session, expected) in [
            (BoneWorkflowCancellationSnapshot.Session(id: "current", sequence: 0, revision: 1, isActive: true, hasObservation: false), BoneWorkflowCancellationRejection.notContinuation),
            (.init(id: "current", sequence: 1, revision: 1, isActive: false, hasObservation: false), .inactiveSession),
            (.init(id: "current", sequence: 1, revision: 1, isActive: true, hasObservation: true), .observationPresent)
        ] {
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(session: session)).decision, .rejected(expected))
        }
    }

    func testOnlyCancellingOrCancelledStatesAreEligible() throws {
        for state in [BoneWorkflowRunState.pending, .running, .pausing, .paused, .waitingForAuthorization, .failed, .completed, .recoveryRequired] {
            XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(state: state)).decision, .rejected(.cancellationNotPersisted))
        }
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(state: .cancelled)).decision, .ready)
    }

    func testDuplicateEffectOrZeroEvidenceRevisionIsInvalid() throws {
        let effect = try BoneWorkflowCancellationSnapshot.Effect(id: .init("effect"), sessionID: "previous", state: .committed)
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(effects: [effect, effect])).decision, .rejected(.invalidEvidence))
        XCTAssertEqual(BoneWorkflowCancellationReadiness().evaluate(try fixture(evidenceRevision: 0)).decision, .rejected(.invalidEvidence))
    }

    func testChangedFactsNeedNewEvaluationEvenWhenRunRevisionUnchanged() throws {
        let old = try fixture()
        let changed = try fixture(effects: [.init(id: .init("effect"), sessionID: "current", state: .outcomeUnknown)], evidenceRevision: 10)
        let evaluator = BoneWorkflowCancellationReadiness()
        XCTAssertEqual(evaluator.evaluate(old).decision, .ready)
        XCTAssertEqual(evaluator.evaluate(changed).decision, .rejected(.unknownEffect))
        XCTAssertEqual(old.runRevision, changed.runRevision)
        XCTAssertNotEqual(evaluator.evaluate(old).evidenceRevision, evaluator.evaluate(changed).evidenceRevision)
    }

    func testQueryErrorsAndCancellationAreNotReadyResults() async throws {
        for cancelled in [false, true] {
            do {
                _ = try await BoneWorkflowCancellationReadiness().evaluate(runID: .init("run"), query: ErrorQuery(cancelled: cancelled))
                XCTFail("Query error must escape")
            } catch {
                if cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error is QueryFailure) }
            }
        }
    }

    func testQueryCannotReturnAnotherRun() async throws {
        let snapshot = try fixture()
        let result = try await BoneWorkflowCancellationReadiness().evaluate(runID: .init("other"), query: FixedQuery(snapshot: snapshot))
        XCTAssertEqual(result.decision, .rejected(.identityMismatch))
        XCTAssertEqual(result.runID, try BoneRunID("other"))
    }

    private func fixture(
        state: BoneWorkflowRunState = .cancelling,
        session: BoneWorkflowCancellationSnapshot.Session? = .init(id: "current", sequence: 1, revision: 1, isActive: true, hasObservation: false),
        effects: [BoneWorkflowCancellationSnapshot.Effect] = [],
        effectsComplete: Bool = true,
        sessionComplete: Bool = true,
        stagesComplete: Bool = true,
        evidenceRevision: UInt64 = 9,
        checks: BoneWorkflowCancellationSnapshot.Checks = .init(hasStageActivity: false, preflightPassed: true, hostAllowsClosure: true)
    ) throws -> BoneWorkflowCancellationSnapshot {
        try .init(runID: .init("run"), runState: state, runRevision: 5, leaseGeneration: 2, evidenceRevision: evidenceRevision,
            sessionComplete: sessionComplete, effectsComplete: effectsComplete, stagesComplete: stagesComplete, session: session, effects: effects, checks: checks)
    }
}

private struct QueryFailure: Error {}
private struct ErrorQuery: BoneWorkflowCancellationReadinessQuery {
    let cancelled: Bool
    func cancellationSnapshot(runID: BoneRunID) async throws -> BoneWorkflowCancellationSnapshot {
        if cancelled { throw CancellationError() }
        throw QueryFailure()
    }
}
private struct FixedQuery: BoneWorkflowCancellationReadinessQuery {
    let snapshot: BoneWorkflowCancellationSnapshot
    func cancellationSnapshot(runID: BoneRunID) async throws -> BoneWorkflowCancellationSnapshot { snapshot }
}

private struct CancellingQuery: BoneWorkflowCancellationReadinessQuery {
    let snapshot: BoneWorkflowCancellationSnapshot
    let cancelInside: Bool
    func cancellationSnapshot(runID: BoneRunID) async throws -> BoneWorkflowCancellationSnapshot {
        if cancelInside { withUnsafeCurrentTask { $0?.cancel() } }
        else { XCTFail("Already cancelled request must not query") }
        return snapshot
    }
}
