import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowCancellationReadinessContractSuiteTests: XCTestCase {
    func testIndependentHostPassesAllCasesWithoutChangingAppliedResults() async throws {
        let results = try await run()
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowCancellationReadinessContractCase.allCases)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testDetectsProjectionDriftWithoutVersionChange() async throws {
        let results = try await run(.driftSession)
        XCTAssertEqual(results.first { $0.scenario == .unstartedContinuation }?.failures, [.evidenceChanged])
    }

    func testEffectRowOrderingDoesNotCountAsEvidenceDrift() async throws {
        let results = try await run(.reorderEffects)
        XCTAssertTrue(results.allSatisfy(\.passed))
    }

    func testRejectsReceiptAndUncommittedMappingMistakes() async throws {
        let results = try await run(.hideUncommitted)
        for scenario in [BoneWorkflowCancellationReadinessContractCase.historicalUncommittedEffect, .receiptWithoutCommit] {
            XCTAssertEqual(results.first { $0.scenario == scenario }?.failures, [.decisionMismatch])
        }
    }

    func testRejectsAdapterHidingObservation() async throws {
        let results = try await run(.hideObservation)
        XCTAssertEqual(results.first { $0.scenario == .observationPresent }?.failures, [.decisionMismatch])
    }

    func testDetectsAdapterHidingUnknownEffect() async throws {
        let results = try await run(.hideUnknown)
        XCTAssertEqual(results.first { $0.scenario == .unknownEffect }?.failures, [.decisionMismatch])
    }

    func testDetectsQueryChangingAlreadyAppliedResult() async throws {
        let results = try await run(.mutateAppliedResult)
        XCTAssertTrue(results.allSatisfy { $0.failures == [.sourceChanged] })
    }

    func testDetectsEvidenceVersionChangingBetweenReads() async throws {
        let results = try await run(.changeVersion)
        XCTAssertTrue(results.allSatisfy { $0.failures == [.evidenceChanged] })
    }

    func testQueryFailuresAndCleanupAreSanitized() async throws {
        let tracker = ReadinessCleanupTracker()
        let results = try await BoneWorkflowCancellationReadinessContractSuite().run { scenario in
            let store = try ReadinessTestHost(scenario: scenario, fault: .queryFailure)
            return .init(runID: store.runID, query: store, verifyUnchanged: { await store.unchanged() }, cleanup: {
                await tracker.record()
                throw ReadinessPrivateError()
            })
        }
        XCTAssertTrue(results.allSatisfy { $0.failures == [.operationFailed, .cleanupFailed] })
        let count = await tracker.count
        XCTAssertEqual(count, BoneWorkflowCancellationReadinessContractCase.allCases.count)
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(ReadinessPrivateError.secret))
        XCTAssertFalse(report.contains("already-applied"))
        XCTAssertFalse(report.contains("readiness-run"))
    }

    func testCancellationPropagatesAfterCleanup() async throws {
        let tracker = ReadinessCleanupTracker()
        do {
            _ = try await BoneWorkflowCancellationReadinessContractSuite().run { scenario in
                let store = try ReadinessTestHost(scenario: scenario, fault: .cancel)
                return .init(runID: store.runID, query: store, verifyUnchanged: { await store.unchanged() },
                    cleanup: { await tracker.record() })
            }
            XCTFail("Cancellation must escape")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation") }
        let count = await tracker.count
        XCTAssertEqual(count, 1)
    }

    func testFactoryFailureDoesNotStopOtherCases() async throws {
        let results = try await BoneWorkflowCancellationReadinessContractSuite().run { scenario in
            if scenario == .unstartedContinuation { throw ReadinessPrivateError() }
            let store = try ReadinessTestHost(scenario: scenario)
            return .init(runID: store.runID, query: store, verifyUnchanged: { await store.unchanged() }, cleanup: {})
        }
        XCTAssertEqual(results.first?.failures, [.fixtureCreationFailed])
        XCTAssertTrue(results.dropFirst().allSatisfy(\.passed))
    }

    private func run(_ fault: ReadinessTestHost.Fault = .none) async throws -> [BoneWorkflowCancellationReadinessContractObservation] {
        try await BoneWorkflowCancellationReadinessContractSuite().run { scenario in
            let store = try ReadinessTestHost(scenario: scenario, fault: fault)
            return .init(runID: store.runID, query: store, verifyUnchanged: { await store.unchanged() }, cleanup: {})
        }
    }
}

private actor ReadinessCleanupTracker {
    var count = 0
    func record() { count += 1 }
}
private struct ReadinessPrivateError: Error, CustomStringConvertible {
    static let secret = "/private/effects.db?token=never-report"
    var description: String { Self.secret }
}

/// Separate in-memory Host facts; not a production session store or a real database transaction proof.
/// No Worker exists in any scenario. Only durable facts can distinguish ready from rejected.
private actor ReadinessTestHost: BoneWorkflowCancellationReadinessQuery {
    enum Fault: Sendable { case none, hideUnknown, mutateAppliedResult, changeVersion, queryFailure, cancel, driftSession, hideUncommitted, hideObservation, reorderEffects }
    private struct EffectRow: Equatable {
        let id: BoneEffectID
        let sessionID: String
        let hasReceipt: Bool
        let commitConfirmed: Bool
        let outcomeUnknown: Bool
    }
    private struct Facts: Equatable {
        var runState: BoneWorkflowRunState
        var runRevision: UInt64
        var generation: UInt64
        var evidenceRevision: UInt64
        var session: BoneWorkflowCancellationSnapshot.Session?
        var effects: [EffectRow]
        var effectsComplete: Bool
        var stageActivity: Bool
        var preflightPassed: Bool
        var appliedResults: [String]
    }
    nonisolated let runID: BoneRunID
    private let initial: Facts
    private var facts: Facts
    private let fault: Fault
    private var queries = 0

    init(scenario: BoneWorkflowCancellationReadinessContractCase, fault: Fault = .none) throws {
        runID = try .init("readiness-run")
        self.fault = fault
        let oldEffect = try EffectRow(id: .init("old-effect"),
            sessionID: scenario == .currentSessionEffect ? "current" : "previous",
            hasReceipt: scenario == .receiptWithoutCommit,
            commitConfirmed: ![.unknownEffect, .historicalUncommittedEffect, .receiptWithoutCommit].contains(scenario),
            outcomeUnknown: scenario == .unknownEffect)
        let olderEffect = try EffectRow(id: .init("older-effect"), sessionID: "older", hasReceipt: true,
            commitConfirmed: true, outcomeUnknown: false)
        // This Host numbers its first execution 1; the SDK projection must be zero-based.
        let hostSequence: UInt64 = scenario == .firstSession ? 1 : 2
        let initial = Facts(runState: .cancelling, runRevision: 5, generation: 2, evidenceRevision: 9,
            session: scenario == .noSessionEvidence ? nil : .init(id: "current", sequence: hostSequence - 1, revision: 1,
                isActive: true, hasObservation: scenario == .observationPresent),
            effects: [oldEffect, olderEffect], effectsComplete: scenario != .incompleteEvidence,
            stageActivity: scenario == .stageActivity, preflightPassed: scenario != .preflightRejected,
            appliedResults: ["already-applied"])
        self.initial = initial
        self.facts = initial
    }

    func unchanged() -> Bool { facts == initial }

    func cancellationSnapshot(runID: BoneRunID) throws -> BoneWorkflowCancellationSnapshot {
        guard runID == self.runID else { throw ReadinessPrivateError() }
        if fault == .queryFailure { throw ReadinessPrivateError() }
        if fault == .cancel { throw CancellationError() }
        if fault == .mutateAppliedResult { facts.appliedResults = [] }
        if fault == .changeVersion { facts.evidenceRevision += 1 }
        queries += 1
        var effects: [BoneWorkflowCancellationSnapshot.Effect] = facts.effects.map { row in
            // Receipt presence must not be confused with confirmed persistent commit.
            .init(id: row.id, sessionID: row.sessionID,
                state: row.outcomeUnknown ? .outcomeUnknown : row.commitConfirmed ? .committed : .uncommitted)
        }
        if fault == .hideUnknown { effects.removeAll { $0.state == .outcomeUnknown } }
        if fault == .hideUncommitted {
            effects = effects.map { .init(id: $0.id, sessionID: $0.sessionID, state: $0.state == .uncommitted ? .committed : $0.state) }
        }
        if fault == .reorderEffects && queries.isMultiple(of: 2) { effects.reverse() }
        var session = facts.session
        if let current = session, fault == .driftSession && queries > 1 {
            session = .init(id: "different", sequence: current.sequence, revision: current.revision + 1,
                isActive: current.isActive, hasObservation: current.hasObservation)
        }
        if let current = session, fault == .hideObservation {
            session = .init(id: current.id, sequence: current.sequence, revision: current.revision,
                isActive: current.isActive, hasObservation: false)
        }
        return .init(runID: runID, runState: facts.runState, runRevision: facts.runRevision, leaseGeneration: facts.generation,
            evidenceRevision: facts.evidenceRevision, sessionComplete: true, effectsComplete: facts.effectsComplete, stagesComplete: true,
            session: session, effects: effects,
            checks: .init(hasStageActivity: facts.stageActivity, preflightPassed: facts.preflightPassed, hostAllowsClosure: true))
    }
}
