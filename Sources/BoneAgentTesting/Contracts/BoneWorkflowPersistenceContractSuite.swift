import Foundation
import BoneAgentKit

/// Behavioral probes, not a crash/disk certification or a forced timeout mechanism.
/// Each case requests a fresh isolated fixture. Operations must cooperate with cancellation;
/// cleanup is awaited in an uncancelled task, including on failure/cancellation/skip.
public struct BoneWorkflowPersistenceContractSuite: Sendable {
    public init() {}

    public func run(factory: BoneWorkflowPersistenceContractFixtureFactory) async throws -> [BoneWorkflowPersistenceContractObservation] {
        var results: [BoneWorkflowPersistenceContractObservation] = []
        for scenario in BoneWorkflowPersistenceContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowPersistenceContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, outcome: .failed([.fixtureCreationFailed])))
                continue
            }
            var outcome: BoneWorkflowPersistenceContractOutcome
            var cancelled = false
            do {
                try Task.checkCancellation()
                outcome = try await probe(scenario, fixture: fixture)
            } catch {
                cancelled = error is CancellationError || Task.isCancelled
                outcome = .failed([(error as? Violation)?.failure ?? .operationFailed])
            }
            // A cancelled parent's task-local flag must not prevent resource disposal.
            // Awaiting this task is intentional: no hard deadline is promised for Host code.
            let cleanup = fixture.cleanup
            do { try await Task.detached { try await cleanup() }.value }
            catch {
                cancelled = cancelled || error is CancellationError
                if case .failed(let failures) = outcome { outcome = .failed(failures + [.cleanupFailed]) }
                else { outcome = .failed([.cleanupFailed]) }
            }
            if cancelled || Task.isCancelled { throw CancellationError() }
            results.append(.init(scenario: scenario, outcome: outcome))
        }
        try Task.checkCancellation()
        return results
    }

    private struct Violation: Error {
        let failure: BoneWorkflowPersistenceContractFailure
    }

    private func require(_ condition: Bool, _ failure: BoneWorkflowPersistenceContractFailure = .snapshotMismatch) throws {
        guard condition else { throw Violation(failure: failure) }
    }

    private func seed(_ store: any BoneWorkflowPersistence) async throws -> BoneWorkflowRunSnapshot {
        let plan = try BoneWorkflowPlan(identity: "persistence-contract", revision: 1,
            steps: [.init(id: .init("step"), kind: "test", revision: 1)])
        let run = try BoneWorkflowRunRecord(id: .init("contract-run"), plan: plan, state: .pending, revision: 0, leaseGeneration: 1)
        let checkpoint = try BoneWorkflowCheckpoint(
            descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: plan.revision),
            payload: Data("{\"value\":0}".utf8), dataClassification: .safeState)
        let initial = BoneWorkflowRunSnapshot(run: run, checkpoint: checkpoint)
        let created = try await store.create(run: run, checkpoint: checkpoint)
        try require(created == copy(initial, revision: 1))
        let loaded = try await store.load(runID: run.id)
        try require(loaded == created)
        return created
    }

    private func copy(
        _ snapshot: BoneWorkflowRunSnapshot,
        state: BoneWorkflowRunState? = nil,
        revision: UInt64? = nil,
        generation: UInt64? = nil,
        identity: String? = nil,
        payload: Data? = nil
    ) throws -> BoneWorkflowRunSnapshot {
        .init(run: .init(id: snapshot.run.id, plan: snapshot.run.plan, state: state ?? snapshot.run.state,
                        revision: revision ?? snapshot.run.revision, leaseGeneration: generation ?? snapshot.run.leaseGeneration),
              checkpoint: try .init(descriptor: .init(formatVersion: snapshot.checkpoint.descriptor.formatVersion,
                    workflowIdentity: identity ?? snapshot.checkpoint.descriptor.workflowIdentity,
                    workflowRevision: snapshot.checkpoint.descriptor.workflowRevision),
                payload: payload ?? snapshot.checkpoint.payload, dataClassification: snapshot.checkpoint.dataClassification,
                retention: snapshot.checkpoint.retention, revision: revision ?? snapshot.checkpoint.revision))
    }

    private func next(_ snapshot: BoneWorkflowRunSnapshot, generation: UInt64? = nil) throws -> BoneWorkflowRunSnapshot {
        try copy(snapshot, state: .running, generation: generation, payload: Data("{\"value\":1}".utf8))
    }

    private func commit(_ snapshot: BoneWorkflowRunSnapshot, to store: any BoneWorkflowPersistence) async throws -> BoneWorkflowRunSnapshot {
        try Task.checkCancellation()
        return try await store.commit(run: snapshot.run, checkpoint: snapshot.checkpoint,
            expectedRevision: snapshot.run.revision, leaseGeneration: snapshot.run.leaseGeneration)
    }

    private func expectRejection(
        _ expected: [BoneWorkflowFailure],
        accepted: BoneWorkflowPersistenceContractFailure,
        operation: () async throws -> BoneWorkflowRunSnapshot
    ) async throws {
        do { _ = try await operation() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            try require((error as? BoneWorkflowFailure).map { expected.contains($0) } == true, .unexpectedRejection)
            return
        }
        throw Violation(failure: accepted)
    }

    private func probe(_ scenario: BoneWorkflowPersistenceContractCase, fixture: BoneWorkflowPersistenceContractFixture) async throws -> BoneWorkflowPersistenceContractOutcome {
        if scenario == .reopenedRead && fixture.reopenAfterClosingPrimary == nil { return .skipped(.reopenAfterClosingPrimary) }
        if scenario == .independentConnectionConsistency && fixture.openIndependentConnection == nil { return .skipped(.independentConnection) }
        let store = fixture.persistence
        let old = try await seed(store)
        switch scenario {
        case .createLoad:
            let proposed = try next(old)
            let saved = try await commit(proposed, to: store)
            try require(saved == copy(proposed, revision: 2))
            let loaded = try await store.load(runID: old.run.id)
            try require(loaded == saved)
        case .rejectedBundleAtomicity:
            for (state, identity, failure): (BoneWorkflowRunState, String?, BoneWorkflowFailure) in [
                (.running, "wrong", .corruptedCheckpoint), (.completed, nil, .invalidStateTransition)
            ] {
                let bad = try copy(old, state: state, identity: identity, payload: Data("{\"value\":1}".utf8))
                try await expectRejection([failure], accepted: .invalidBundleAccepted) { try await commit(bad, to: store) }
                let loaded = try await store.load(runID: old.run.id)
                try require(loaded == old, .rejectedWriteChangedSnapshot)
            }
        case .concurrentCAS:
            try await checkCAS(old, first: store, second: store)
        case .generationFencing:
            try await checkFencing(old, owner: store, worker: store)
        case .reopenedRead:
            guard let reopen = fixture.reopenAfterClosingPrimary else { return .skipped(.reopenAfterClosingPrimary) }
            let proposed = try next(old)
            let saved = try await commit(proposed, to: store)
            try require(saved == copy(proposed, revision: 2))
            let reopened = try await reopen()
            let loaded = try await reopened.load(runID: old.run.id)
            try require(loaded == saved)
        case .independentConnectionConsistency:
            guard let open = fixture.openIndependentConnection else { return .skipped(.independentConnection) }
            let second = try await open()
            let loaded = try await second.load(runID: old.run.id)
            try require(loaded == old)
            try await checkCAS(old, first: store, second: second)
            let current = try await store.load(runID: old.run.id)
            try await checkFencing(current, owner: second, worker: store)
        }
        try Task.checkCancellation()
        return .passed
    }

    private enum CASResult: Sendable {
        case committed(proposed: BoneWorkflowRunSnapshot, saved: BoneWorkflowRunSnapshot)
        case conflict
        case unexpectedRejection
    }

    private func checkCAS(_ old: BoneWorkflowRunSnapshot, first: any BoneWorkflowPersistence, second: any BoneWorkflowPersistence) async throws {
        let proposals = [try next(old), try copy(old, state: .running, payload: Data("{\"value\":2}".utf8))]
        let outcomes = try await withThrowingTaskGroup(of: CASResult.self) { group in
            for (store, proposed) in zip([first, second], proposals) {
                group.addTask {
                    do { return .committed(proposed: proposed, saved: try await commit(proposed, to: store)) }
                    catch {
                        if error is CancellationError || Task.isCancelled { throw CancellationError() }
                        return error as? BoneWorkflowFailure == .revisionConflict ? .conflict : .unexpectedRejection
                    }
                }
            }
            var values: [CASResult] = []
            for try await value in group { values.append(value) }
            return values
        }
        var winners: [(proposed: BoneWorkflowRunSnapshot, saved: BoneWorkflowRunSnapshot)] = []
        for outcome in outcomes {
            switch outcome {
            case .committed(let proposed, let saved): winners.append((proposed, saved))
            case .conflict: break
            case .unexpectedRejection: throw Violation(failure: .unexpectedRejection)
            }
        }
        try require(winners.count == 1, .casWinnerCount)
        let expected = try copy(winners[0].proposed, revision: old.run.revision + 1)
        try require(winners[0].saved == expected)
        for store in [first, second] {
            let loaded = try await store.load(runID: old.run.id)
            try require(loaded == expected)
        }
    }

    private func checkFencing(_ old: BoneWorkflowRunSnapshot, owner: any BoneWorkflowPersistence, worker: any BoneWorkflowPersistence) async throws {
        let takeover = try await owner.acquireLease(runID: old.run.id, expectedRevision: old.run.revision)
        let expected = try copy(old, revision: old.run.revision + 1, generation: old.run.leaseGeneration + 1)
        try require(takeover == expected, .generationNotAdvanced)
        try await expectRejection([.revisionConflict], accepted: .staleWorkerAccepted) {
            try await worker.acquireLease(runID: old.run.id, expectedRevision: old.run.revision)
        }
        for store in [owner, worker] {
            let unchanged = try await store.load(runID: old.run.id)
            try require(unchanged == takeover, .rejectedWriteChangedSnapshot)
        }
        for stale in [try next(old), try next(takeover, generation: old.run.leaseGeneration)] {
            // Both fields conflict in the first request; Hosts may check either first.
            // A fresh revision isolates the generation check and must yield leaseConflict.
            let failures: [BoneWorkflowFailure] = stale.run.revision == old.run.revision
                ? [.revisionConflict, .leaseConflict] : [.leaseConflict]
            try await expectRejection(failures, accepted: .staleWorkerAccepted) { try await commit(stale, to: worker) }
            for store in [owner, worker] {
                let unchanged = try await store.load(runID: old.run.id)
                try require(unchanged == takeover, .rejectedWriteChangedSnapshot)
            }
        }
        let proposed = try next(takeover)
        let saved = try await commit(proposed, to: owner)
        try require(saved == copy(proposed, revision: takeover.run.revision + 1))
        let loaded = try await worker.load(runID: old.run.id)
        try require(loaded == saved)
    }
}
