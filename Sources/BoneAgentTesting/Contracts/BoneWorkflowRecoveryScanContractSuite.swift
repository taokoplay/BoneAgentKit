import Foundation
import BoneAgentKit

public enum BoneWorkflowRecoveryScanContractCase: String, CaseIterable, Codable, Sendable {
    case emptyScan, recoveryCandidates, readOnlyScan, quarantinedRecordIsolation
}

public enum BoneWorkflowRecoveryScanContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, snapshotMismatch, quarantineCountMismatch, cleanupFailed
}

public enum BoneWorkflowRecoveryScanContractCapability: String, Codable, Sendable {
    /// 仅是测试故障注入能力，不表示生产扫描可以忽略坏行或计数。
    case injectQuarantinedRecord
}

public enum BoneWorkflowRecoveryScanContractOutcome: Equatable, Codable, Sendable {
    case passed
    case skipped(BoneWorkflowRecoveryScanContractCapability)
    case failed([BoneWorkflowRecoveryScanContractFailure])
}

public struct BoneWorkflowRecoveryScanContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowRecoveryScanContractCase
    public let outcome: BoneWorkflowRecoveryScanContractOutcome

    public init(scenario: BoneWorkflowRecoveryScanContractCase, outcome: BoneWorkflowRecoveryScanContractOutcome) {
        self.scenario = scenario
        self.outcome = outcome
    }
}

/// 每个场景提供空的隔离 scope。persistence 与 recoveryScan 必须指向同一 scope。
/// cleanup 负责所有资源；factory 返回前失败由 factory 自己清理。回调不得访问生产数据。
public struct BoneWorkflowRecoveryScanContractFixture: Sendable {
    public let persistence: any BoneWorkflowPersistence
    public let recoveryScan: any BoneWorkflowRecoveryScan
    /// 每次调用添加一条独立、确定不可用的持久记录，不改动已有行；不可仅模拟扫描返回值。
    /// 例如不能解码或 Run/Checkpoint revision 不匹配的行。生产实现不必开放此入口。
    public let injectQuarantinedRecord: (@Sendable () async throws -> Void)?
    public let cleanup: @Sendable () async throws -> Void

    public init(
        persistence: any BoneWorkflowPersistence,
        recoveryScan: any BoneWorkflowRecoveryScan,
        injectQuarantinedRecord: (@Sendable () async throws -> Void)? = nil,
        cleanup: @escaping @Sendable () async throws -> Void
    ) {
        self.persistence = persistence
        self.recoveryScan = recoveryScan
        self.injectQuarantinedRecord = injectQuarantinedRecord
        self.cleanup = cleanup
    }
}

/// 完整 scope 行为探针；不验证数据库隔离级别、权限边界或物理存储。报告固定白名单且无正文。
public struct BoneWorkflowRecoveryScanContractSuite: Sendable {
    public init() {}

    public func run(
        factory: @Sendable (BoneWorkflowRecoveryScanContractCase) async throws -> BoneWorkflowRecoveryScanContractFixture
    ) async throws -> [BoneWorkflowRecoveryScanContractObservation] {
        var results: [BoneWorkflowRecoveryScanContractObservation] = []
        for scenario in BoneWorkflowRecoveryScanContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowRecoveryScanContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, outcome: .failed([.fixtureCreationFailed])))
                continue
            }
            var outcome: BoneWorkflowRecoveryScanContractOutcome
            var cancelled = false
            do {
                try Task.checkCancellation()
                outcome = try await probe(scenario, fixture: fixture)
            } catch {
                cancelled = error is CancellationError || Task.isCancelled
                outcome = .failed([(error as? Violation)?.failure ?? .operationFailed])
            }
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

    private struct Violation: Error { let failure: BoneWorkflowRecoveryScanContractFailure }

    private func require(_ condition: Bool, _ failure: BoneWorkflowRecoveryScanContractFailure = .snapshotMismatch) throws {
        guard condition else { throw Violation(failure: failure) }
    }

    private func check(
        _ result: BoneWorkflowRecoveryScanResult,
        expected: [BoneWorkflowRunSnapshot],
        quarantined: Int
    ) throws {
        try require(result.quarantinedRunCount == quarantined, .quarantineCountMismatch)
        let actualByID = Dictionary(uniqueKeysWithValues: result.trustedRuns.map { ($0.run.id, $0) })
        let expectedByID = Dictionary(uniqueKeysWithValues: expected.map { ($0.run.id, $0) })
        try require(actualByID == expectedByID)
    }

    private func seed(_ store: any BoneWorkflowPersistence) async throws -> [BoneWorkflowRunSnapshot] {
        let plan = try BoneWorkflowPlan(identity: "scan-contract", revision: 1,
            steps: [.init(id: .init("step"), kind: "work", revision: 1)])
        let states: [BoneWorkflowRunState] = [.pending, .running, .pausing, .paused, .waitingForAuthorization,
            .cancelling, .recoveryRequired, .completed, .failed, .cancelled]
        var snapshots: [BoneWorkflowRunSnapshot] = []
        for (index, state) in states.enumerated() {
            try Task.checkCancellation()
            let run = try BoneWorkflowRunRecord(id: .init("scan-\(index)"), plan: plan, state: state, revision: 0, leaseGeneration: 7)
            let checkpoint = try BoneWorkflowCheckpoint(
                descriptor: .init(formatVersion: 1, workflowIdentity: plan.identity, workflowRevision: 1),
                payload: Data(" {\"used\":3} ".utf8), dataClassification: .safeState, retention: .untilExplicitCleanup)
            let saved = try await store.create(run: run, checkpoint: checkpoint)
            try require(saved.run.state == state && saved.run.plan == plan && saved.run.id == run.id
                && saved.run.revision == 1 && saved.run.leaseGeneration == 7)
            let expectedCheckpoint = try BoneWorkflowCheckpoint(descriptor: checkpoint.descriptor, payload: checkpoint.payload,
                dataClassification: checkpoint.dataClassification, retention: checkpoint.retention, revision: 1)
            try require(saved.checkpoint == expectedCheckpoint)
            snapshots.append(saved)
        }
        return snapshots
    }

    private func probe(_ scenario: BoneWorkflowRecoveryScanContractCase, fixture: BoneWorkflowRecoveryScanContractFixture) async throws -> BoneWorkflowRecoveryScanContractOutcome {
        if scenario == .quarantinedRecordIsolation && fixture.injectQuarantinedRecord == nil {
            return .skipped(.injectQuarantinedRecord)
        }
        let empty = try await fixture.recoveryScan.recoverableRunScan()
        try check(empty, expected: [], quarantined: 0)
        if scenario == .emptyScan { return .passed }
        let all = try await seed(fixture.persistence)
        // Explicit expected set, not the production predicate: detect incorrect state selection.
        let expected = Array(all.prefix(7))
        let first = try await fixture.recoveryScan.recoverableRunScan()
        try check(first, expected: expected, quarantined: 0)
        if scenario == .quarantinedRecordIsolation, let inject = fixture.injectQuarantinedRecord {
            for count in 1...2 {
                try await inject()
                for _ in 0..<2 {
                    let result = try await fixture.recoveryScan.recoverableRunScan()
                    try check(result, expected: expected, quarantined: count)
                }
            }
        } else if scenario == .readOnlyScan {
            let repeated = try await fixture.recoveryScan.recoverableRunScan()
            try check(repeated, expected: expected, quarantined: 0)
        }
        // Even excluded terminal records must remain untouched by scanning/quarantine.
        for saved in all {
            let loaded = try await fixture.persistence.load(runID: saved.run.id)
            try require(loaded == saved)
        }
        try Task.checkCancellation()
        return .passed
    }
}
