import Foundation

public enum BoneWorkflowRunState: String, Codable, Equatable, Sendable {
    case pending, running, pausing, paused, waitingForAuthorization
    case cancelling, cancelled, failed, completed, recoveryRequired

    public func transitioned(to next: Self) throws -> Self {
        let allowed: Set<Self>
        switch self {
        case .pending: allowed = [.running, .cancelling, .cancelled]
        case .running: allowed = [.pausing, .waitingForAuthorization, .cancelling, .failed, .completed, .recoveryRequired]
        case .pausing: allowed = [.paused, .cancelling, .recoveryRequired]
        case .paused: allowed = [.running, .cancelling]
        case .waitingForAuthorization: allowed = [.running, .cancelling, .failed]
        case .cancelling: allowed = [.cancelled, .recoveryRequired]
        case .cancelled, .failed, .completed, .recoveryRequired: allowed = []
        }
        guard allowed.contains(next) else { throw BoneWorkflowFailure.invalidStateTransition }
        return next
    }
}

public enum BoneWorkflowStepState: String, Codable, Equatable, Sendable {
    case pending, ready, running, waiting, paused, succeeded, failed, skipped, cancelled, commitUncertain

    public func transitioned(to next: Self) throws -> Self {
        let allowed: Set<Self>
        switch self {
        case .pending: allowed = [.ready, .skipped, .cancelled]
        case .ready: allowed = [.running, .paused, .cancelled]
        case .running: allowed = [.waiting, .paused, .succeeded, .failed, .cancelled, .commitUncertain]
        case .waiting: allowed = [.running, .paused, .failed, .cancelled]
        case .paused: allowed = [.ready, .cancelled]
        case .succeeded, .failed, .skipped, .cancelled, .commitUncertain: allowed = []
        }
        guard allowed.contains(next) else { throw BoneWorkflowFailure.invalidStateTransition }
        return next
    }
}

public enum BoneWorkflowAttemptState: String, Codable, Equatable, Sendable {
    case reserved, executing, resultPrepared, committing, committed
    case failed, cancelled, superseded, outcomeUnknown

    public func transitioned(to next: Self) throws -> Self {
        let allowed: Set<Self>
        switch self {
        case .reserved: allowed = [.executing, .cancelled, .superseded]
        case .executing: allowed = [.resultPrepared, .failed, .cancelled, .outcomeUnknown]
        case .resultPrepared: allowed = [.committing, .failed, .cancelled]
        case .committing: allowed = [.committed, .failed, .outcomeUnknown]
        case .committed, .failed, .cancelled, .superseded, .outcomeUnknown: allowed = []
        }
        guard allowed.contains(next) else { throw BoneWorkflowFailure.invalidStateTransition }
        return next
    }
}
