import Foundation

public enum BoneWorkflowExecutionSessionError: Error, Codable, Equatable, Sendable {
    case invalidInput, invalidHash, admissionMismatch, invalidState, sequenceConflict, revisionConflict
    case bindingMismatch, nonceAlreadyUsed, missingPermit, pendingPermit, identityReused, missingLedger, counterOverflow
}

/// 通用执行会话信封，admission 不透明；hash 是完整性绑定，不是签名或业务授权。
public struct BoneWorkflowExecutionSession: Codable, Equatable, Sendable {
    public static let maximumAdmissionByteCount = 4 * 1_048_576
    public enum State: String, Codable, Sendable { case active, completed, cancelled, failed, recoveryRequired }
    public struct Request: Codable, Equatable, Sendable {
        /// 零基，初次0，续执行必须恰好+1。
        public let sequence: UInt64
        public let operationID: String
        public let effectID: BoneEffectID
        public let bindingHash: String
        public let admission: Data
        public let admissionHash: String

        public init(sequence: UInt64, operationID: String, effectID: BoneEffectID, bindingHash: String, admission: Data) throws {
            guard Self.validID(operationID), admission.count <= BoneWorkflowExecutionSession.maximumAdmissionByteCount else {
                throw BoneWorkflowExecutionSessionError.invalidInput
            }
            guard Self.validHash(bindingHash) else { throw BoneWorkflowExecutionSessionError.invalidHash }
            self.sequence = sequence; self.operationID = operationID; self.effectID = effectID
            self.bindingHash = bindingHash; self.admission = admission
            self.admissionHash = BoneSHA256.hexDigest(admission)
        }
        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(sequence: c.decode(UInt64.self, forKey: .sequence), operationID: c.decode(String.self, forKey: .operationID),
                effectID: c.decode(BoneEffectID.self, forKey: .effectID), bindingHash: c.decode(String.self, forKey: .bindingHash),
                admission: c.decode(Data.self, forKey: .admission))
            guard try c.decode(String.self, forKey: .admissionHash) == admissionHash else { throw BoneWorkflowExecutionSessionError.admissionMismatch }
        }
        static func validHash(_ value: String) -> Bool {
            value.count == 64 && value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdef").contains($0) }
        }
        static func validID(_ value: String) -> Bool {
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 128
        }
    }
    public let runID: BoneRunID
    public let sequence: UInt64
    public let operationID: String
    public let effectID: BoneEffectID
    public let bindingHash: String
    public let admission: Data
    public let admissionHash: String
    public let state: State
    public let revision: UInt64

    init(runID: BoneRunID, request: Request, state: State = .active, revision: UInt64 = 1) {
        self.runID = runID; self.sequence = request.sequence; self.operationID = request.operationID
        self.effectID = request.effectID; self.bindingHash = request.bindingHash
        self.admission = request.admission; self.admissionHash = request.admissionHash
        self.state = state; self.revision = revision
    }
    func finishing(_ target: State) throws -> Self {
        guard state == .active, target != .active else { throw BoneWorkflowExecutionSessionError.invalidState }
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else { throw BoneWorkflowExecutionSessionError.counterOverflow }
        let request = try Request(sequence: sequence, operationID: operationID, effectID: effectID, bindingHash: bindingHash, admission: admission)
        return .init(runID: runID, request: request, state: target, revision: next)
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw BoneWorkflowExecutionSessionError.invalidInput }
        let request = try Request(sequence: c.decode(UInt64.self, forKey: .sequence), operationID: c.decode(String.self, forKey: .operationID),
            effectID: c.decode(BoneEffectID.self, forKey: .effectID), bindingHash: c.decode(String.self, forKey: .bindingHash),
            admission: c.decode(Data.self, forKey: .admission))
        guard try c.decode(String.self, forKey: .admissionHash) == request.admissionHash else { throw BoneWorkflowExecutionSessionError.admissionMismatch }
        let state = try c.decode(State.self, forKey: .state)
        let revision = try c.decode(UInt64.self, forKey: .revision)
        guard revision == (state == .active ? 1 : 2) else { throw BoneWorkflowExecutionSessionError.invalidInput }
        self.init(runID: try c.decode(BoneRunID.self, forKey: .runID), request: request, state: state, revision: revision)
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(1, forKey: .schemaVersion); try c.encode(runID, forKey: .runID)
        try c.encode(sequence, forKey: .sequence); try c.encode(operationID, forKey: .operationID)
        try c.encode(effectID, forKey: .effectID); try c.encode(bindingHash, forKey: .bindingHash)
        try c.encode(admission, forKey: .admission); try c.encode(admissionHash, forKey: .admissionHash)
        try c.encode(state, forKey: .state); try c.encode(revision, forKey: .revision)
    }
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, runID, sequence, operationID, effectID, bindingHash, admission, admissionHash, state, revision
    }
}
