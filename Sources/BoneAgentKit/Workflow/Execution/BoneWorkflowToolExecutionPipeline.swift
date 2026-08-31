import Foundation

public enum BoneWorkflowToolExecutionError: Error, Equatable, Sendable {
    case invalidContext
    case pipelineUnavailable
    case authorizationRejected
    case effectStoreRejected
    case cancelledBeforeExecution
    case toolExecutionFailed
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
            throw BoneWorkflowToolExecutionError.effectStoreRejected
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
                throw BoneWorkflowToolExecutionError.effectStoreRejected
            }
            throw BoneWorkflowToolExecutionError.cancelledBeforeExecution
        }

        do {
            try await effectStore.markExecutionStarted(
                effectID: context.effectID,
                leaseGeneration: context.leaseGeneration
            )
        } catch {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }

        let output: Data
        do {
            // executionStarted 后任何 throw（含取消）都不能证明副作用未发生；保留无 Receipt 的
            // executionStarted 事实，让 Recovery Planner 进入 reconcile/outcomeUnknown。
            output = try await operation()
        } catch {
            throw BoneWorkflowToolExecutionError.toolExecutionFailed
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
        } catch let error as BoneWorkflowToolExecutionError {
            throw error
        } catch {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
    }

    /// 重启时只解释已持久化事实，不在无 Receipt 的不确定窗口盲目重执行。
    public func recoveryAction(
        effectID: BoneEffectID,
        currentLeaseGeneration: UInt64
    ) async throws -> BoneWorkflowRecoveryAction {
        guard let effectStore else { throw BoneWorkflowToolExecutionError.pipelineUnavailable }
        do {
            guard let snapshot = try await effectStore.recoverySnapshot(
                effectID: effectID,
                currentLeaseGeneration: currentLeaseGeneration
            ) else {
                throw BoneWorkflowToolExecutionError.effectStoreRejected
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
