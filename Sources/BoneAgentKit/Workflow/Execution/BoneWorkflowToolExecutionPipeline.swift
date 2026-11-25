import Foundation

public enum BoneWorkflowToolExecutionError: Error, Equatable, Sendable {
    case invalidContext
    case identityMismatch
    case pipelineUnavailable
    case authorizationRejected
    case effectStoreRejected
    case cancelledBeforeExecution
    case toolExecutionFailed
    /// executionStarted 后执行抛错，不能证明副作用未发生；必须先恢复/对账。
    case outcomeUnknown
    /// 控制面写入或执行 Receipt 的提交未确认；必须按原 Effect identity 读取持久化事实恢复。
    case recoveryRequired
}

/// 通用高风险 Tool 管线：Grant consume → Intent → executionStarted → Tool → Receipt → commit。
///
/// 它不知道 App 业务类型；Host Store 负责把 commitReceipt 与业务 Checkpoint 原子提交。
public struct BoneWorkflowToolExecutionPipeline: Sendable {
    private let effectStore: (any BoneWorkflowEffectStore)?
    private let recoveryPlanner: BoneWorkflowRecoveryPlanner
    private let commitObserver: BoneWorkflowToolCommitObserver

    public init(
        effectStore: (any BoneWorkflowEffectStore)? = nil,
        recoveryPlanner: BoneWorkflowRecoveryPlanner = .init(),
        commitObserver: BoneWorkflowToolCommitObserver = .init()
    ) {
        self.effectStore = effectStore
        self.recoveryPlanner = recoveryPlanner
        self.commitObserver = commitObserver
    }

    public func execute(
        arguments: Data,
        definition: BoneAgentToolDefinition,
        context: BoneWorkflowToolExecutionContext?,
        operation: @escaping @Sendable () async throws -> Data
    ) async throws -> Data {
        let impact: BoneToolImpact
        do { impact = try definition.requiredImpact() }
        catch { throw BoneWorkflowToolExecutionError.pipelineUnavailable }

        if impact.isLocalReadOnly {
            return try await operation()
        }
        guard impact.requiresHostAuthorization,
              let context,
              let effectStore,
              let schemaVersion = definition.schemaVersion else {
            throw BoneWorkflowToolExecutionError.pipelineUnavailable
        }
        if let currentScope = BoneWorkflowExecutionScopeContext.current {
            guard context.executionScope == currentScope,
                  context.runID == currentScope.runID,
                  context.stepID == currentScope.stepID,
                  context.attemptID == currentScope.attemptID,
                  context.leaseGeneration == currentScope.leaseGeneration else {
                throw BoneWorkflowToolExecutionError.identityMismatch
            }
        }

        let canonicalCall: BoneCanonicalToolCall
        let validation: BoneAuthorizationValidation
        let intent: BoneEffectIntent
        do {
            canonicalCall = try BoneCanonicalToolCall(
                toolID: definition.id,
                toolVersion: definition.version,
                schemaVersion: schemaVersion,
                arguments: arguments
            )
            validation = .init(
                ticketID: context.ticketID,
                runID: context.runID,
                stepID: context.stepID,
                attemptID: context.attemptID,
                toolCallID: context.toolCallID,
                canonicalCall: canonicalCall,
                principal: context.principal,
                resourceScope: context.resourceScope,
                resourceRevision: context.resourceRevision,
                impact: impact,
                nonce: context.authorizationNonce,
                nowUptime: context.nowUptime
            )
            intent = try BoneEffectIntent(
                id: context.effectID,
                sessionID: context.executionScope?.sessionID,
                runID: context.runID,
                stepID: context.stepID,
                attemptID: context.attemptID,
                toolCallID: context.toolCallID,
                recoveryStrategy: context.recoveryStrategy,
                idempotencyKey: context.idempotencyKey,
                argumentsDigest: canonicalCall.argumentsDigest,
                phase: .intentPersisted,
                leaseGeneration: context.leaseGeneration
            )
        } catch {
            throw BoneWorkflowToolExecutionError.authorizationRejected
        }
        do {
            try await effectStore.consumeAuthorizationAndPersistIntent(validation, intent: intent)
        } catch is BoneAuthorizationError {
            throw BoneWorkflowToolExecutionError.authorizationRejected
        } catch {
            throw BoneWorkflowToolExecutionError.recoveryRequired
        }

        // Intent 已成为恢复事实；取消只能在 executionStarted 之前安全生效。
        do { try Task.checkCancellation() }
        catch {
            do {
                try await effectStore.persistCancellation(
                    effectID: context.effectID,
                    leaseGeneration: context.leaseGeneration
                )
            } catch {
                throw BoneWorkflowToolExecutionError.recoveryRequired
            }
            throw BoneWorkflowToolExecutionError.cancelledBeforeExecution
        }

        do {
            try await effectStore.markExecutionStarted(
                effectID: context.effectID,
                leaseGeneration: context.leaseGeneration
            )
        } catch {
            throw BoneWorkflowToolExecutionError.recoveryRequired
        }

        let output: Data
        do {
            // executionStarted 后任何 throw（含取消）都不能证明副作用未发生；保留无 Receipt 的
            // executionStarted 事实，让 Recovery Planner 进入 reconcile/outcomeUnknown。
            output = try await operation()
        } catch {
            throw BoneWorkflowToolExecutionError.outcomeUnknown
        }

        do {
            let receipt = try BoneEffectReceipt(
                effectID: context.effectID,
                outcome: .succeeded,
                resultDigest: BoneSHA256.hexDigest(output),
                leaseGeneration: context.leaseGeneration
            )
            try await effectStore.recordReceipt(receipt)
            try await effectStore.commitReceipt(effectID: context.effectID, leaseGeneration: context.leaseGeneration)
            await commitObserver.receive(effectID: context.effectID, outcome: .succeeded)
            return output
        } catch {
            // 包括取消：执行结果已知不等于 Receipt 已提交，不可降级为普通失败。
            throw BoneWorkflowToolExecutionError.recoveryRequired
        }
    }

    /// 提交已确认的历史 Receipt，不重新执行 Tool。
    ///
    /// 该入口只接受 Recovery Planner 判定为 `commitReceipt` 的事实。Host Store
    /// 负责把 Receipt 与业务 Checkpoint 放在同一提交边界，提交结果未知时由调用方
    /// 重新读取 Effect 事实，不得把错误当作已回滚。
    /// - Parameters:
    ///   - effectID: 待提交 Receipt 的 Effect 身份。
    ///   - currentLeaseGeneration: 当前 Run 持有的 lease generation。
    /// - Returns: 提交成功后返回 `completed`，其他 Planner 动作原样返回。
    /// - Throws: Effect Store 不可用、事实缺失或提交失败时抛出 Tool 管线错误或 Store 错误。
    public func commitRecoveredReceipt(
        effectID: BoneEffectID,
        currentLeaseGeneration: UInt64,
        expectedScope: BoneWorkflowEffectRecoveryScope? = nil
    ) async throws -> BoneWorkflowRecoveryAction {
        guard let effectStore else { throw BoneWorkflowToolExecutionError.pipelineUnavailable }
        guard let snapshot = try await effectStore.recoverySnapshot(
            effectID: effectID,
            currentLeaseGeneration: currentLeaseGeneration
        ) else {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
        if let expectedScope, !expectedScope.matches(snapshot.intent) {
            throw BoneWorkflowToolExecutionError.identityMismatch
        }
        let action = recoveryPlanner.plan(snapshot)
        guard case .commitReceipt = action else { return action }
        try await effectStore.commitRecoveredReceipt(
            effectID: effectID,
            receiptLeaseGeneration: snapshot.intent.leaseGeneration,
            currentLeaseGeneration: currentLeaseGeneration
        )
        return .completed
    }

    /// 重启时只解释已持久化事实，不在无 Receipt 的不确定窗口盲目重执行。
    public func recoveryAction(
        effectID: BoneEffectID,
        currentLeaseGeneration: UInt64,
        expectedScope: BoneWorkflowEffectRecoveryScope? = nil
    ) async throws -> BoneWorkflowRecoveryAction {
        guard let effectStore else { throw BoneWorkflowToolExecutionError.pipelineUnavailable }
        do {
            guard let snapshot = try await effectStore.recoverySnapshot(
                effectID: effectID,
                currentLeaseGeneration: currentLeaseGeneration
            ) else {
                throw BoneWorkflowToolExecutionError.effectStoreRejected
            }
            if let expectedScope, !expectedScope.matches(snapshot.intent) {
                throw BoneWorkflowToolExecutionError.identityMismatch
            }
            let action = recoveryPlanner.plan(snapshot)
            switch action {
            case .execute where snapshot.intent.leaseGeneration != currentLeaseGeneration:
                try await effectStore.resumePreparedEffect(
                    effectID: effectID,
                    expectedExecutionLeaseGeneration: snapshot.intent.leaseGeneration,
                    currentLeaseGeneration: currentLeaseGeneration
                )
            case .commitReceipt where snapshot.intent.leaseGeneration != currentLeaseGeneration:
                try await effectStore.commitRecoveredReceipt(
                    effectID: effectID,
                    receiptLeaseGeneration: snapshot.intent.leaseGeneration,
                    currentLeaseGeneration: currentLeaseGeneration
                )
                return .completed
            case .recoveryRequired(.outcomeUnknown):
                try await effectStore.persistOutcomeUnknown(
                    effectID: effectID,
                    currentLeaseGeneration: currentLeaseGeneration
                )
            default:
                break
            }
            return action
        } catch let error as BoneWorkflowToolExecutionError {
            throw error
        } catch {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
    }
}
