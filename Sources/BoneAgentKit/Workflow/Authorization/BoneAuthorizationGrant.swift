import Foundation

public enum BoneAuthorizationError: Error, Codable, Equatable, Sendable {
    case invalidCanonicalCall
    case invalidGrant
    case denied
    case notFound
    case expired
    case alreadyConsumed
    case bindingMismatch
    case resourceRevisionChanged
    case duplicateTicket
}

public struct BoneAuthorizationGrant: Codable, Equatable, Sendable {
    public let ticketID: BoneAuthorizationTicketID
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let toolCallID: BoneToolCallID
    public let canonicalCall: BoneCanonicalToolCall
    public let principal: String
    public let resourceScope: String
    public let resourceRevision: UInt64
    public let impact: BoneToolImpact
    public let grantedAtUptime: TimeInterval
    public let expiresAtUptime: TimeInterval
    public let nonce: String

    public init(
        ticketID: BoneAuthorizationTicketID,
        runID: BoneRunID,
        stepID: BoneStepID,
        attemptID: BoneAttemptID,
        toolCallID: BoneToolCallID,
        canonicalCall: BoneCanonicalToolCall,
        principal: String,
        resourceScope: String,
        resourceRevision: UInt64,
        impact: BoneToolImpact,
        grantedAtUptime: TimeInterval,
        expiresAtUptime: TimeInterval,
        nonce: String
    ) throws {
        guard !principal.isEmpty, principal.count <= 128,
              !resourceScope.isEmpty, resourceScope.count <= 256,
              !nonce.isEmpty, nonce.count <= 128,
              grantedAtUptime.isFinite, expiresAtUptime.isFinite,
              expiresAtUptime > grantedAtUptime else {
            throw BoneAuthorizationError.invalidGrant
        }
        self.ticketID = ticketID
        self.runID = runID
        self.stepID = stepID
        self.attemptID = attemptID
        self.toolCallID = toolCallID
        self.canonicalCall = canonicalCall
        self.principal = principal
        self.resourceScope = resourceScope
        self.resourceRevision = resourceRevision
        self.impact = impact
        self.grantedAtUptime = grantedAtUptime
        self.expiresAtUptime = expiresAtUptime
        self.nonce = nonce
    }
}

public struct BoneAuthorizationValidation: Sendable {
    public let ticketID: BoneAuthorizationTicketID
    public let runID: BoneRunID
    public let stepID: BoneStepID
    public let attemptID: BoneAttemptID
    public let toolCallID: BoneToolCallID
    public let canonicalCall: BoneCanonicalToolCall
    public let principal: String
    public let resourceScope: String
    public let resourceRevision: UInt64
    public let impact: BoneToolImpact
    public let nonce: String
    public let nowUptime: TimeInterval

    public init(
        ticketID: BoneAuthorizationTicketID, runID: BoneRunID, stepID: BoneStepID,
        attemptID: BoneAttemptID, toolCallID: BoneToolCallID,
        canonicalCall: BoneCanonicalToolCall, principal: String,
        resourceScope: String, resourceRevision: UInt64,
        impact: BoneToolImpact, nonce: String, nowUptime: TimeInterval
    ) {
        self.ticketID = ticketID; self.runID = runID; self.stepID = stepID
        self.attemptID = attemptID; self.toolCallID = toolCallID
        self.canonicalCall = canonicalCall; self.principal = principal
        self.resourceScope = resourceScope; self.resourceRevision = resourceRevision
        self.impact = impact; self.nonce = nonce; self.nowUptime = nowUptime
    }
}
