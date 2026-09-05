import Foundation
import XCTest
import BoneAgentKit
import BoneAgentTesting

final class WorkflowPersistenceContractSuiteTests: XCTestCase {
    func testMemoryPassesCoreAndExplicitlySkipsUnavailableCapabilities() async throws {
        let results = try await BoneWorkflowPersistenceContractSuite().run { _ in
            .init(persistence: BoneInMemoryWorkflowPersistence(), cleanup: {})
        }
        XCTAssertEqual(results.map(\.scenario), BoneWorkflowPersistenceContractCase.allCases)
        XCTAssertEqual(results.map(\.outcome), [
            .passed, .passed, .passed, .passed,
            .skipped(.reopenAfterClosingPrimary), .skipped(.independentConnection)
        ])
    }
}

extension WorkflowPersistenceContractSuiteTests {
    func testGenerationFirstHostPassesFencing() async throws {
        let results = try await runFault(.generationFirst)
        XCTAssertEqual(outcome(.generationFencing, in: results), .passed)
    }

    func testDetectsCASLoserOverwritingWinnerPayload() async throws {
        let results = try await runFault(.loserWrites)
        XCTAssertEqual(outcome(.concurrentCAS, in: results), .failed([.snapshotMismatch]))
    }

    func testDetectsAcceptedStaleLeaseAcquisition() async throws {
        let results = try await runFault(.acceptStaleLease)
        XCTAssertEqual(outcome(.generationFencing, in: results), .failed([.staleWorkerAccepted]))
    }

    func testDetectsMutationDuringRejectedStaleLeaseAcquisition() async throws {
        let results = try await runFault(.mutateStaleLease)
        XCTAssertEqual(outcome(.generationFencing, in: results), .failed([.rejectedWriteChangedSnapshot]))
    }

    func testFreshRevisionStillRequiresLeaseConflict() async throws {
        let results = try await runFault(.wrongFenceError)
        XCTAssertEqual(outcome(.generationFencing, in: results), .failed([.unexpectedRejection]))
    }

    func testDetectsMultipleCASWinners() async throws {
        let results = try await runFault(.multipleWinners)
        XCTAssertEqual(outcome(.concurrentCAS, in: results), .failed([.casWinnerCount]))
    }

    func testDetectsPartialCommitAfterRejection() async throws {
        let results = try await runFault(.partialCommit)
        XCTAssertEqual(outcome(.rejectedBundleAtomicity, in: results), .failed([.rejectedWriteChangedSnapshot]))
    }

    func testDetectsMissingGenerationFence() async throws {
        let results = try await runFault(.missingFence)
        XCTAssertEqual(outcome(.generationFencing, in: results), .failed([.staleWorkerAccepted]))
    }

    func testCleanupRunsForEveryIsolatedFixtureIncludingFailuresAndSkips() async throws {
        let tracker = FixtureTracker()
        _ = try await BoneWorkflowPersistenceContractSuite().run { scenario in
            await tracker.created(scenario)
            return .init(persistence: FaultyPersistence(.partialCommit), cleanup: { await tracker.cleaned(scenario) })
        }
        let created = await tracker.creations
        let cleaned = await tracker.cleanups
        XCTAssertEqual(created, BoneWorkflowPersistenceContractCase.allCases)
        XCTAssertEqual(cleaned, created)
    }

    func testOperationCancellationPropagatesAfterCleanup() async throws {
        let tracker = FixtureTracker()
        do {
            _ = try await BoneWorkflowPersistenceContractSuite().run { scenario in
                await tracker.created(scenario)
                return .init(persistence: FaultyPersistence(.cancelLoad), cleanup: { await tracker.cleaned(scenario) })
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned, [.createLoad])
    }

    func testParentCancellationAfterFactoryReturnStillCleansInUncancelledTask() async throws {
        let tracker = FixtureTracker()
        let task = Task {
            try await BoneWorkflowPersistenceContractSuite().run { scenario in
                await tracker.created(scenario)
                withUnsafeCurrentTask { $0?.cancel() }
                return .init(persistence: BoneInMemoryWorkflowPersistence(), cleanup: {
                    try Task.checkCancellation()
                    await tracker.cleaned(scenario)
                })
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned, [.createLoad])
    }

    func testCleanupFailureIsReportedWithoutReplacingProbeFailure() async throws {
        let results = try await BoneWorkflowPersistenceContractSuite().run { _ in
            .init(persistence: FaultyPersistence(.multipleWinners), cleanup: { throw SecretError() })
        }
        XCTAssertEqual(outcome(.concurrentCAS, in: results), .failed([.casWinnerCount, .cleanupFailed]))
        XCTAssertEqual(outcome(.createLoad, in: results), .failed([.cleanupFailed]))
        XCTAssertEqual(outcome(.reopenedRead, in: results), .failed([.cleanupFailed]))
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(SecretError.secret))
        XCTAssertFalse(report.contains("contract-run"))
        XCTAssertFalse(report.contains("payload"))
    }

    func testFactoryFailureUsesFixedCategoryAndContinuesOtherCases() async throws {
        let tracker = FixtureTracker()
        let results = try await BoneWorkflowPersistenceContractSuite().run { scenario in
            if scenario == .createLoad { throw SecretError() }
            return .init(persistence: BoneInMemoryWorkflowPersistence(), cleanup: { await tracker.cleaned(scenario) })
        }
        XCTAssertEqual(results.count, 6)
        XCTAssertEqual(outcome(.createLoad, in: results), .failed([.fixtureCreationFailed]))
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned.count, 5)
    }

    func testFactoryCancellationPropagatesWithoutPretendingFixtureWasAcquired() async throws {
        do {
            _ = try await BoneWorkflowPersistenceContractSuite().run { _ in throw CancellationError() }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
    }

    func testDeclaredButBrokenConnectionsFailRatherThanSkip() async throws {
        let tracker = FixtureTracker()
        let results = try await BoneWorkflowPersistenceContractSuite().run { scenario in
            .init(persistence: BoneInMemoryWorkflowPersistence(),
                  reopenAfterClosingPrimary: { BoneInMemoryWorkflowPersistence() },
                  openIndependentConnection: { BoneInMemoryWorkflowPersistence() },
                  cleanup: { await tracker.cleaned(scenario) })
        }
        XCTAssertEqual(outcome(.reopenedRead, in: results), .failed([.operationFailed]))
        XCTAssertEqual(outcome(.independentConnectionConsistency, in: results), .failed([.operationFailed]))
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned.count, 6)
    }

    func testOptionalConnectionCancellationStillCleans() async throws {
        let tracker = FixtureTracker()
        do {
            _ = try await BoneWorkflowPersistenceContractSuite().run { scenario in
                .init(persistence: BoneInMemoryWorkflowPersistence(),
                      reopenAfterClosingPrimary: { throw CancellationError() },
                      cleanup: { await tracker.cleaned(scenario) })
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned, Array(BoneWorkflowPersistenceContractCase.allCases.prefix(5)))
    }

    func testCleanupCancellationPropagatesAndStopsFurtherFixtures() async throws {
        let tracker = FixtureTracker()
        do {
            _ = try await BoneWorkflowPersistenceContractSuite().run { scenario in
                await tracker.created(scenario)
                return .init(persistence: BoneInMemoryWorkflowPersistence(), cleanup: {
                    await tracker.cleaned(scenario)
                    throw CancellationError()
                })
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
        let created = await tracker.creations
        let cleaned = await tracker.cleanups
        XCTAssertEqual(created, [.createLoad])
        XCTAssertEqual(cleaned, created)
    }

    func testCleanupFailureDoesNotSwallowOperationCancellation() async throws {
        let tracker = FixtureTracker()
        do {
            _ = try await BoneWorkflowPersistenceContractSuite().run { scenario in
                .init(persistence: FaultyPersistence(.cancelLoad), cleanup: {
                    await tracker.cleaned(scenario)
                    throw SecretError()
                })
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Wrong cancellation type") }
        let cleaned = await tracker.cleanups
        XCTAssertEqual(cleaned, [.createLoad])
    }

    func testUnknownAdapterErrorsAreSanitized() async throws {
        let results = try await runFault(.secretLoad)
        XCTAssertEqual(outcome(.createLoad, in: results), .failed([.operationFailed]))
        let report = String(decoding: try JSONEncoder().encode(results), as: UTF8.self)
        XCTAssertFalse(report.contains(SecretError.secret))
    }

    private func runFault(_ fault: FaultyPersistence.Fault) async throws -> [BoneWorkflowPersistenceContractObservation] {
        try await BoneWorkflowPersistenceContractSuite().run { _ in
            .init(persistence: FaultyPersistence(fault), cleanup: {})
        }
    }

    private func outcome(_ scenario: BoneWorkflowPersistenceContractCase, in results: [BoneWorkflowPersistenceContractObservation]) -> BoneWorkflowPersistenceContractOutcome? {
        results.first { $0.scenario == scenario }?.outcome
    }
}

private actor FixtureTracker {
    var creations: [BoneWorkflowPersistenceContractCase] = []
    var cleanups: [BoneWorkflowPersistenceContractCase] = []
    func created(_ scenario: BoneWorkflowPersistenceContractCase) { creations.append(scenario) }
    func cleaned(_ scenario: BoneWorkflowPersistenceContractCase) { cleanups.append(scenario) }
}

private struct SecretError: Error, CustomStringConvertible {
    static let secret = "/host/private/database.sqlite?token=DO_NOT_REPORT"
    var description: String { Self.secret }
}

/// Test-only variants, including a valid generation-first check ordering and deliberately broken adapters.
private actor FaultyPersistence: BoneWorkflowPersistence {
    enum Fault: Sendable { case multipleWinners, partialCommit, missingFence, cancelLoad, secretLoad, generationFirst, loserWrites, acceptStaleLease, mutateStaleLease, wrongFenceError }
    private let fault: Fault
    private let base = BoneInMemoryWorkflowPersistence()
    private var partial: BoneWorkflowRunSnapshot?
    init(_ fault: Fault) { self.fault = fault }

    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot {
        try await base.create(run: run, checkpoint: checkpoint)
    }

    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot {
        if fault == .cancelLoad { throw CancellationError() }
        if fault == .secretLoad { throw SecretError() }
        if let partial { return partial }
        return try await base.load(runID: runID)
    }

    func commit(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint, expectedRevision: UInt64, leaseGeneration: UInt64) async throws -> BoneWorkflowRunSnapshot {
        if fault == .generationFirst {
            let current = try await base.load(runID: run.id)
            guard current.run.leaseGeneration == leaseGeneration, run.leaseGeneration == leaseGeneration else {
                throw BoneWorkflowFailure.leaseConflict
            }
        }
        var actualRun = run
        var actualGeneration = leaseGeneration
        if fault == .missingFence {
            let current = try await base.load(runID: run.id)
            actualGeneration = current.run.leaseGeneration
            actualRun = .init(id: run.id, plan: run.plan, state: run.state, revision: run.revision, leaseGeneration: actualGeneration)
        }
        do {
            return try await base.commit(run: actualRun, checkpoint: checkpoint, expectedRevision: expectedRevision, leaseGeneration: actualGeneration)
        } catch {
            if fault == .wrongFenceError, error as? BoneWorkflowFailure == .leaseConflict {
                throw BoneWorkflowFailure.revisionConflict
            }
            if fault == .loserWrites, error as? BoneWorkflowFailure == .revisionConflict {
                let winner = try await base.load(runID: run.id)
                partial = .init(run: winner.run, checkpoint: try .init(
                    descriptor: checkpoint.descriptor, payload: checkpoint.payload,
                    dataClassification: checkpoint.dataClassification, retention: checkpoint.retention,
                    revision: winner.checkpoint.revision))
            }
            if fault == .multipleWinners, error as? BoneWorkflowFailure == .revisionConflict {
                return try await base.load(runID: run.id)
            }
            if fault == .partialCommit, error as? BoneWorkflowFailure == .corruptedCheckpoint {
                let old = try await base.load(runID: run.id)
                partial = .init(run: run, checkpoint: old.checkpoint)
            }
            throw error
        }
    }

    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        if fault == .acceptStaleLease || fault == .mutateStaleLease {
            let current = try await base.load(runID: runID)
            if current.run.revision != expectedRevision {
                let changed = try await base.acquireLease(runID: runID, expectedRevision: current.run.revision)
                if fault == .mutateStaleLease { throw BoneWorkflowFailure.revisionConflict }
                return changed
            }
        }
        return try await base.acquireLease(runID: runID, expectedRevision: expectedRevision)
    }
}
