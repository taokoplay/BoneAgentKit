import Foundation

public protocol BoneAuthorizationHandler: Sendable {
    func consume(_ validation: BoneAuthorizationValidation) async throws
}

/// 缺少 Host 授权实现时的默认 fail-closed Handler。
public struct BoneDenyingAuthorizationHandler: BoneAuthorizationHandler, Sendable {
    public init() {}
    public func consume(_ validation: BoneAuthorizationValidation) async throws {
        _ = validation
        throw BoneAuthorizationError.denied
    }
}

public actor BoneInMemoryAuthorizationHandler: BoneAuthorizationHandler {
    private var grants: [BoneAuthorizationTicketID: BoneAuthorizationGrant] = [:]
    private var consumed = Set<BoneAuthorizationTicketID>()

    public init() {}

    public func store(_ grant: BoneAuthorizationGrant) throws {
        guard grants[grant.ticketID] == nil, !consumed.contains(grant.ticketID) else {
            throw BoneAuthorizationError.duplicateTicket
        }
        grants[grant.ticketID] = grant
    }

    public func consume(_ validation: BoneAuthorizationValidation) throws {
        guard !consumed.contains(validation.ticketID) else {
            throw BoneAuthorizationError.alreadyConsumed
        }
        guard let grant = grants[validation.ticketID] else {
            throw BoneAuthorizationError.notFound
        }
        guard validation.nowUptime.isFinite,
              validation.nowUptime >= grant.grantedAtUptime,
              validation.nowUptime <= grant.expiresAtUptime else {
            throw BoneAuthorizationError.expired
        }
        guard validation.resourceRevision == grant.resourceRevision else {
            throw BoneAuthorizationError.resourceRevisionChanged
        }
        guard validation.runID == grant.runID,
              validation.stepID == grant.stepID,
              validation.attemptID == grant.attemptID,
              validation.toolCallID == grant.toolCallID,
              validation.canonicalCall == grant.canonicalCall,
              validation.principal == grant.principal,
              validation.resourceScope == grant.resourceScope,
              validation.impact == grant.impact,
              validation.nonce == grant.nonce else {
            throw BoneAuthorizationError.bindingMismatch
        }
        consumed.insert(validation.ticketID)
        grants.removeValue(forKey: validation.ticketID)
    }
}
