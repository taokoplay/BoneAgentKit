import Foundation
import BoneAgentKit

public enum BoneWorkflowRunControllerContractCase: String, CaseIterable, Codable, Sendable {
    case pendingStart, pauseResumeFencing, terminalCannotRevive, cancellationOrdering, recoveryPreservesCheckpoint
}

public enum BoneWorkflowRunControllerContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, staleWorkerAccepted, unexpectedRejection, cleanupFailed
}

/// 空 failures 表示本项通过；报告不含 payload、标识、路径或原始 Error。没有可跳过场景。
public struct BoneWorkflowRunControllerContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowRunControllerContractCase
    public let failures: [BoneWorkflowRunControllerContractFailure]
    public var passed: Bool { failures.isEmpty }

    public init(scenario: BoneWorkflowRunControllerContractCase, failures: [BoneWorkflowRunControllerContractFailure]) {
        self.scenario = scenario
        self.failures = failures
    }
}

/// 每项需要独立命名空间，可在同一项创建多个 Run。复用 Persistence fixture 的资源清理协议，
/// 不使用 reopen/独立连接回调；本套件不是数据库持久性或 Worker 停止证明。
public struct BoneWorkflowRunControllerContractSuite: Sendable {
    public init() {}

    public func run(
        factory: @Sendable (BoneWorkflowRunControllerContractCase) async throws -> BoneWorkflowPersistenceContractFixture
    ) async throws -> [BoneWorkflowRunControllerContractObservation] {
        var observations: [BoneWorkflowRunControllerContractObservation] = []
        for scenario in BoneWorkflowRunControllerContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowPersistenceContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                observations.append(.init(scenario: scenario, failures: [.fixtureCreationFailed]))
                continue
            }
            var failures: [BoneWorkflowRunControllerContractFailure] = []
            var cancelled = false
            do {
                try Task.checkCancellation()
                try await probe(scenario, store: fixture.persistence)
            } catch {
                cancelled = error is CancellationError || Task.isCancelled
                failures.append((error as? Violation)?.failure ?? .operationFailed)
            }
            let cleanup = fixture.cleanup
            do { try await Task.detached { try await cleanup() }.value }
            catch {
                cancelled = cancelled || error is CancellationError
                failures.append(.cleanupFailed)
            }
            if cancelled || Task.isCancelled { throw CancellationError() }
            observations.append(.init(scenario: scenario, failures: failures))
        }
        try Task.checkCancellation()
        return observations
    }

    private struct Violation: Error { let failure: BoneWorkflowRunControllerContractFailure }

    private func require(_ condition: Bool, _ failure: BoneWorkflowRunControllerContractFailure = .snapshotMismatch) throws {
        guard condition else { throw Violation(failure: failure) }
    }

    private func rejected(_ failure: BoneWorkflowFailure, operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            try require(error as? BoneWorkflowFailure == failure, .unexpectedRejection)
            return
        }
        throw Violation(failure: .staleWorkerAccepted)
    }

    private func seed(_ controller: BoneWorkflowRunController, id: String = "control-run") async throws -> BoneWorkflowRunSnapshot {
        let plan = try BoneWorkflowPlan(identity: "control-contract", revision: 1,
            steps: [.init(id: .init("step"), kind: "work", revision: 1)])
        return try await controller.createRun(runID: .init(id), plan: plan, checkpoint: .init(
            descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1),
            payload: Data("{\"requestLimit\":10,\"used\":3,\"deadline\":1000}".utf8),
            dataClassification: .safeState, retention: .untilExplicitCleanup))
    }

    private func unchangedContent(_ first: BoneWorkflowRunSnapshot, _ second: BoneWorkflowRunSnapshot) throws {
        try require(first.run.id == second.run.id && first.run.plan == second.run.plan)
        try require(first.checkpoint.payload == second.checkpoint.payload && first.checkpoint.descriptor == second.checkpoint.descriptor)
        try require(first.checkpoint.dataClassification == second.checkpoint.dataClassification && first.checkpoint.retention == second.checkpoint.retention)
    }

    private func fence(_ old: BoneWorkflowRunSnapshot, against current: BoneWorkflowRunSnapshot, store: any BoneWorkflowPersistence) async throws {
        // Fresh revision isolates generation fencing; checking the controller alone is insufficient.
        let stale = BoneWorkflowRunRecord(id: current.run.id, plan: current.run.plan, state: current.run.state,
            revision: current.run.revision, leaseGeneration: old.run.leaseGeneration)
        try await rejected(.leaseConflict) {
            _ = try await store.commit(run: stale, checkpoint: current.checkpoint,
                expectedRevision: current.run.revision, leaseGeneration: stale.leaseGeneration)
        }
        let loaded = try await store.load(runID: current.run.id)
        try require(loaded == current)
    }

    private func probe(_ scenario: BoneWorkflowRunControllerContractCase, store: any BoneWorkflowPersistence) async throws {
        let controller = BoneWorkflowRunController(persistence: store)
        let created = try await seed(controller)
        try require(created.run.state == .pending && created.run.leaseGeneration == 0 && created.run.revision == 1)
        switch scenario {
        case .pendingStart:
            let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
            try require(running.run.state == .running && running.run.leaseGeneration == 1 && running.run.revision == 3)
            try unchangedContent(created, running)
            try await fence(created, against: running, store: store)
        case .pauseResumeFencing:
            let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
            let paused = try await controller.pauseExecution(runID: created.run.id, expectedRevision: running.run.revision)
            try require(paused.run.state == .paused && paused.run.leaseGeneration == running.run.leaseGeneration + 1)
            try await fence(running, against: paused, store: store)
            let resumed = try await controller.resumePausedExecution(runID: created.run.id, expectedRevision: paused.run.revision)
            try require(resumed.run.state == .running && resumed.run.leaseGeneration == paused.run.leaseGeneration + 1)
            try unchangedContent(created, resumed)
            try await fence(paused, against: resumed, store: store)
        case .terminalCannotRevive:
            for (index, state) in [BoneWorkflowRunState.completed, .failed, .cancelled, .recoveryRequired].enumerated() {
                let seed = try await seed(controller, id: "terminal-\(index)")
                var running = try await controller.beginExecution(runID: seed.run.id, expectedRevision: 1)
                if state == .cancelled {
                    running = try await controller.requestCancellation(runID: seed.run.id, expectedRevision: running.run.revision)
                }
                let terminal = try await controller.reconcileTerminal(runID: seed.run.id, state: state,
                    expectedRevision: running.run.revision, leaseGeneration: running.run.leaseGeneration)
                for action in 0..<3 {
                    try await rejected(.invalidStateTransition) {
                        switch action {
                        case 0: _ = try await controller.beginExecution(runID: seed.run.id, expectedRevision: terminal.run.revision)
                        case 1: _ = try await controller.resumePausedExecution(runID: seed.run.id, expectedRevision: terminal.run.revision)
                        default: _ = try await controller.recover(runID: seed.run.id, expectedRevision: terminal.run.revision)
                        }
                    }
                }
                let loaded = try await store.load(runID: seed.run.id)
                try require(loaded == terminal)
            }
        case .cancellationOrdering:
            let marker = StopMarker()
            try await rejected(.invalidStateTransition) {
                try await controller.stopRequestedExecution(runID: created.run.id, expectedRevision: 1, leaseGeneration: 0) { _ in
                    await marker.record()
                }
            }
            let premature = await marker.count
            try require(premature == 0)
            let cancelling = try await controller.requestCancellation(runID: created.run.id, expectedRevision: 1)
            let repeated = try await controller.requestCancellation(runID: created.run.id, expectedRevision: cancelling.run.revision)
            try require(repeated == cancelling && cancelling.run.state == .cancelling)
            try await controller.stopRequestedExecution(runID: created.run.id, expectedRevision: cancelling.run.revision,
                leaseGeneration: cancelling.run.leaseGeneration) { snapshot in
                    let durable = try await store.load(runID: snapshot.run.id)
                    try require(durable == cancelling)
                    await marker.record()
                }
            let stopped = await marker.count
            try require(stopped == 1)
            let stillCancelling = try await store.load(runID: created.run.id)
            try require(stillCancelling == cancelling)
        case .recoveryPreservesCheckpoint:
            let running = try await controller.beginExecution(runID: created.run.id, expectedRevision: 1)
            let recovered = try await controller.recover(runID: created.run.id, expectedRevision: running.run.revision)
            try require(recovered.run.state == running.run.state && recovered.run.leaseGeneration == running.run.leaseGeneration + 1)
            try unchangedContent(running, recovered)
            try await rejected(.revisionConflict) {
                _ = try await controller.recover(runID: created.run.id, expectedRevision: running.run.revision)
            }
            try await fence(running, against: recovered, store: store)
        }
        try Task.checkCancellation()
    }

    private actor StopMarker {
        var count = 0
        func record() { count += 1 }
    }
}
