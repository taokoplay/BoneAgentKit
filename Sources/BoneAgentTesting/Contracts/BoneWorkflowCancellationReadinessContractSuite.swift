import Foundation
import BoneAgentKit

/// 工厂必须在真实测试 backing 中准备对应事实，除场景指定差异外满足全部 ready 条件。
public enum BoneWorkflowCancellationReadinessContractCase: String, CaseIterable, Codable, Sendable {
    /// cancelling、active continuation、无 observation/当前 Effect/stage，历史 Effect 均 committed。
    case unstartedContinuation
    /// 在正常候选中增加一条历史 outcomeUnknown Effect，保留已应用结果。
    case unknownEffect
    /// 新实例无当前 session 证据；不能因内存中无 Worker 而宣布停止。
    case noSessionEvidence
    /// session 存在且无 observation，但全历史 Effect 查询不完整。
    case incompleteEvidence
    /// 当前 session 已有 stage 工作/产物，其他条件满足。
    case stageActivity
    case observationPresent
    case currentSessionEffect
    case historicalUncommittedEffect
    /// 外部成功并已有 Receipt，但未完成持久化提交；必须投影为 uncommitted。
    case receiptWithoutCommit
    case preflightRejected
    case firstSession
}

public enum BoneWorkflowCancellationReadinessContractFailure: String, Codable, Sendable {
    case fixtureCreationFailed, operationFailed, decisionMismatch, evidenceChanged, sourceChanged, cleanupFailed
}

public struct BoneWorkflowCancellationReadinessContractObservation: Equatable, Codable, Sendable {
    public let scenario: BoneWorkflowCancellationReadinessContractCase
    public let failures: [BoneWorkflowCancellationReadinessContractFailure]
    public var passed: Bool { failures.isEmpty }

    public init(scenario: BoneWorkflowCancellationReadinessContractCase, failures: [BoneWorkflowCancellationReadinessContractFailure]) {
        self.scenario = scenario
        self.failures = failures
    }
}

/// 每项隔离命名空间；query 读取真实测试数据，不应仅伪造期望 decision。
/// verifyUnchanged 必须核对 Run、session、Effect、stage 及已应用结果与初始化时完全一致。
/// 资源在 factory 返回前失败由 factory 自己清理；返回后由 suite 等待 cleanup。
public struct BoneWorkflowCancellationReadinessContractFixture: Sendable {
    public let runID: BoneRunID
    public let query: any BoneWorkflowCancellationReadinessQuery
    public let verifyUnchanged: @Sendable () async throws -> Bool
    public let cleanup: @Sendable () async throws -> Void

    public init(
        runID: BoneRunID,
        query: any BoneWorkflowCancellationReadinessQuery,
        verifyUnchanged: @escaping @Sendable () async throws -> Bool,
        cleanup: @escaping @Sendable () async throws -> Void
    ) {
        self.runID = runID
        self.query = query
        self.verifyUnchanged = verifyUnchanged
        self.cleanup = cleanup
    }
}

/// 无写入能力的行为套件。十一项必需，无 skipped；固定失败分类，不输出原始错误/数据/标识。
public struct BoneWorkflowCancellationReadinessContractSuite: Sendable {
    public init() {}

    public func run(
        factory: @Sendable (BoneWorkflowCancellationReadinessContractCase) async throws -> BoneWorkflowCancellationReadinessContractFixture
    ) async throws -> [BoneWorkflowCancellationReadinessContractObservation] {
        var results: [BoneWorkflowCancellationReadinessContractObservation] = []
        for scenario in BoneWorkflowCancellationReadinessContractCase.allCases {
            try Task.checkCancellation()
            let fixture: BoneWorkflowCancellationReadinessContractFixture
            do { fixture = try await factory(scenario) }
            catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                results.append(.init(scenario: scenario, failures: [.fixtureCreationFailed]))
                continue
            }
            var failures: [BoneWorkflowCancellationReadinessContractFailure] = []
            var cancelled = false
            do {
                try Task.checkCancellation()
                try await probe(scenario, fixture: fixture)
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
            results.append(.init(scenario: scenario, failures: failures))
        }
        try Task.checkCancellation()
        return results
    }

    private struct Violation: Error { let failure: BoneWorkflowCancellationReadinessContractFailure }

    private func require(_ condition: Bool, _ failure: BoneWorkflowCancellationReadinessContractFailure) throws {
        guard condition else { throw Violation(failure: failure) }
    }

    private func equivalent(_ a: BoneWorkflowCancellationSnapshot, _ b: BoneWorkflowCancellationSnapshot) -> Bool {
        a.runID == b.runID && a.runState == b.runState && a.runRevision == b.runRevision
            && a.leaseGeneration == b.leaseGeneration && a.evidenceRevision == b.evidenceRevision
            && a.sessionComplete == b.sessionComplete && a.effectsComplete == b.effectsComplete
            && a.stagesComplete == b.stagesComplete && a.session == b.session && a.checks == b.checks
            && a.effects.sorted { $0.id.rawValue < $1.id.rawValue } == b.effects.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    private func probe(_ scenario: BoneWorkflowCancellationReadinessContractCase, fixture: BoneWorkflowCancellationReadinessContractFixture) async throws {
        let baseline = try await fixture.verifyUnchanged()
        try require(baseline, .sourceChanged)
        let evaluator = BoneWorkflowCancellationReadiness()
        let firstSnapshot = try await fixture.query.cancellationSnapshot(runID: fixture.runID)
        try Task.checkCancellation()
        let secondSnapshot = try await fixture.query.cancellationSnapshot(runID: fixture.runID)
        try Task.checkCancellation()
        try require(firstSnapshot.runID == fixture.runID && secondSnapshot.runID == fixture.runID, .decisionMismatch)
        // Compare the entire projection, not just decision/version: adapters may drift without advancing a version.
        // Effects are a set of facts; harmless database row ordering is not evidence drift.
        try require(equivalent(firstSnapshot, secondSnapshot), .evidenceChanged)
        let first = evaluator.evaluate(firstSnapshot)
        let expected: BoneWorkflowCancellationDecision
        switch scenario {
        case .unstartedContinuation: expected = .ready
        case .unknownEffect: expected = .rejected(.unknownEffect)
        case .noSessionEvidence: expected = .rejected(.missingSession)
        case .incompleteEvidence: expected = .rejected(.incompleteEvidence)
        case .stageActivity: expected = .rejected(.stageActivity)
        case .observationPresent: expected = .rejected(.observationPresent)
        case .currentSessionEffect: expected = .rejected(.currentSessionHasEffects)
        case .historicalUncommittedEffect, .receiptWithoutCommit: expected = .rejected(.uncommittedEffect)
        case .preflightRejected: expected = .rejected(.preflightRejected)
        case .firstSession: expected = .rejected(.notContinuation)
        }
        try require(first.decision == expected, .decisionMismatch)
        let unchanged = try await fixture.verifyUnchanged()
        try require(unchanged, .sourceChanged)
        try Task.checkCancellation()
    }
}
