import Foundation

/// Run scope 的session序列与nonce墓碑；解码必须重新校验完整历史与permit绑定。
/// 编码不含nonce原文；墓碑不能清除后复用nonce，可信存储/防回滚仍由Host负责。
public struct BoneWorkflowSessionLedger: Codable, Equatable, Sendable {
    public struct Permit: Codable, Equatable, Sendable {
        public let runID: BoneRunID
        public let previousSequence: UInt64
        public let previousSessionRevision: UInt64
        public let nextSequence: UInt64
        public let operationID: String
        public let effectID: BoneEffectID
        public let bindingHash: String
        public let admissionHash: String
        public let nonceHash: String
    }
    /// nonce属于敏感准入材料；Command刻意不Codable，Host不可直接记录原nonce日志。
    public enum Command: Equatable, Sendable {
        case finish(BoneWorkflowExecutionSession.State)
        case prepare(BoneWorkflowExecutionSession.Request, nonce: String)
        case consume(BoneWorkflowExecutionSession.Request, nonce: String)
        case revoke
    }
    public let runID: BoneRunID
    public let initialRequest: BoneWorkflowExecutionSession.Request
    public private(set) var revision: UInt64
    public private(set) var sessions: [BoneWorkflowExecutionSession]
    public private(set) var pendingPermit: Permit?
    public private(set) var issuedNonceHashes: Set<String>
    public var current: BoneWorkflowExecutionSession { sessions[sessions.count - 1] }

    public init(runID: BoneRunID, initial: BoneWorkflowExecutionSession.Request) throws {
        guard initial.sequence == 0 else { throw BoneWorkflowExecutionSessionError.sequenceConflict }
        self.runID = runID; self.initialRequest = initial; self.revision = 1
        self.sessions = [.init(runID: runID, request: initial)]
        self.pendingPermit = nil; self.issuedNonceHashes = []
    }
    /// 仅纯推进。prepare需Host先完成领域准入；consume仍需Host原子复核变化的安全事实。
    public func applying(_ command: Command) throws -> Self {
        let (revision, overflow) = self.revision.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowExecutionSessionError.counterOverflow }
        var next = self
        next.revision = revision
        switch command {
        case .finish(let state):
            guard pendingPermit == nil else { throw BoneWorkflowExecutionSessionError.pendingPermit }
            next.sessions[sessions.count - 1] = try current.finishing(state)
        case .prepare(let request, let nonce):
            try canContinue(request)
            guard pendingPermit == nil else { throw BoneWorkflowExecutionSessionError.pendingPermit }
            let hash = try nonceHash(nonce)
            guard !issuedNonceHashes.contains(hash) else { throw BoneWorkflowExecutionSessionError.nonceAlreadyUsed }
            next.issuedNonceHashes.insert(hash)
            next.pendingPermit = .init(runID: runID, previousSequence: current.sequence, previousSessionRevision: current.revision,
                nextSequence: request.sequence, operationID: request.operationID, effectID: request.effectID,
                bindingHash: request.bindingHash, admissionHash: request.admissionHash, nonceHash: hash)
        case .consume(let request, let nonce):
            guard let permit = pendingPermit else { throw BoneWorkflowExecutionSessionError.missingPermit }
            try canContinue(request)
            let hash = try nonceHash(nonce)
            guard permit.runID == runID, permit.previousSequence == current.sequence,
                  permit.previousSessionRevision == current.revision,
                  permit.nextSequence == request.sequence, permit.operationID == request.operationID,
                  permit.effectID == request.effectID, permit.bindingHash == request.bindingHash,
                  permit.admissionHash == request.admissionHash, permit.nonceHash == hash else {
                throw BoneWorkflowExecutionSessionError.bindingMismatch
            }
            next.pendingPermit = nil
            next.sessions.append(.init(runID: runID, request: request))
        case .revoke:
            guard pendingPermit != nil else { throw BoneWorkflowExecutionSessionError.missingPermit }
            next.pendingPermit = nil
        }
        return next
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw BoneWorkflowExecutionSessionError.invalidInput }
        runID = try c.decode(BoneRunID.self, forKey: .runID)
        initialRequest = try c.decode(BoneWorkflowExecutionSession.Request.self, forKey: .initialRequest)
        revision = try c.decode(UInt64.self, forKey: .revision)
        sessions = try c.decode([BoneWorkflowExecutionSession].self, forKey: .sessions)
        pendingPermit = try c.decodeIfPresent(Permit.self, forKey: .pendingPermit)
        issuedNonceHashes = try c.decode(Set<String>.self, forKey: .issuedNonceHashes)
        guard revision > 0, !sessions.isEmpty, initialRequest.sequence == 0,
              Set(sessions.map(\.operationID)).count == sessions.count,
              Set(sessions.map(\.effectID)).count == sessions.count,
              issuedNonceHashes.allSatisfy(BoneWorkflowExecutionSession.Request.validHash),
              issuedNonceHashes.count >= sessions.count - 1 else { throw BoneWorkflowExecutionSessionError.invalidInput }
        if sessions.count == 1, current.state == .active || current.state == .recoveryRequired {
            guard issuedNonceHashes.isEmpty else { throw BoneWorkflowExecutionSessionError.invalidInput }
        }
        for (index, session) in sessions.enumerated() {
            guard session.runID == runID, session.sequence == UInt64(index),
                  index == sessions.count - 1 || (session.state != .active && session.state != .recoveryRequired) else {
                throw BoneWorkflowExecutionSessionError.invalidInput
            }
        }
        let first = sessions[0]
        guard first.operationID == initialRequest.operationID, first.effectID == initialRequest.effectID,
              first.bindingHash == initialRequest.bindingHash, first.admission == initialRequest.admission else {
            throw BoneWorkflowExecutionSessionError.bindingMismatch
        }
        // Each issued nonce corresponds to prepare + consume/revoke, except the one still pending.
        let (twiceIssued, overflow1) = UInt64(issuedNonceHashes.count).multipliedReportingOverflow(by: 2)
        let finished = UInt64(sessions.filter { $0.state != .active }.count)
        let (base, overflow2) = UInt64(1).addingReportingOverflow(finished)
        let (total, overflow3) = base.addingReportingOverflow(twiceIssued)
        guard !overflow1 && !overflow2 && !overflow3,
              revision == total - (pendingPermit == nil ? 0 : 1) else { throw BoneWorkflowExecutionSessionError.invalidInput }
        if let permit = pendingPermit {
            let (nextSequence, overflow) = current.sequence.addingReportingOverflow(1)
            guard !overflow, current.state != .active && current.state != .recoveryRequired,
                  permit.runID == runID, permit.previousSequence == current.sequence,
                  permit.previousSessionRevision == current.revision, permit.nextSequence == nextSequence,
                  BoneWorkflowExecutionSession.Request.validID(permit.operationID),
                  BoneWorkflowExecutionSession.Request.validHash(permit.bindingHash),
                  BoneWorkflowExecutionSession.Request.validHash(permit.admissionHash),
                  issuedNonceHashes.contains(permit.nonceHash),
                  issuedNonceHashes.count >= sessions.count,
                  !sessions.contains(where: { $0.operationID == permit.operationID || $0.effectID == permit.effectID }) else {
                throw BoneWorkflowExecutionSessionError.bindingMismatch
            }
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion); try c.encode(runID, forKey: .runID)
        try c.encode(initialRequest, forKey: .initialRequest); try c.encode(revision, forKey: .revision)
        try c.encode(sessions, forKey: .sessions); try c.encodeIfPresent(pendingPermit, forKey: .pendingPermit)
        try c.encode(issuedNonceHashes, forKey: .issuedNonceHashes)
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, initialRequest, revision, sessions, pendingPermit, issuedNonceHashes
    }

    private func canContinue(_ request: BoneWorkflowExecutionSession.Request) throws {
        guard current.state != .active && current.state != .recoveryRequired else { throw BoneWorkflowExecutionSessionError.invalidState }
        let (sequence, overflow) = current.sequence.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowExecutionSessionError.counterOverflow }
        guard request.sequence == sequence else { throw BoneWorkflowExecutionSessionError.sequenceConflict }
        guard !sessions.contains(where: { $0.operationID == request.operationID || $0.effectID == request.effectID }) else {
            throw BoneWorkflowExecutionSessionError.identityReused
        }
    }
    private func nonceHash(_ nonce: String) throws -> String {
        guard BoneWorkflowExecutionSession.Request.validID(nonce) else { throw BoneWorkflowExecutionSessionError.invalidInput }
        return BoneSHA256.hexDigest(Data(nonce.utf8))
    }
}
