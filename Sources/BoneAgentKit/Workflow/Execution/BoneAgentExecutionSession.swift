import Foundation

/// 长期 Agent 执行会话的控制面状态。
///
/// 该状态只描述执行身份、恢复边界和当前关注事项，不保存消息正文、Tool 参数、Tool 结果或 Provider continuation。
public enum BoneAgentExecutionSessionState: String, Codable, Equatable, Sendable {
    case active
    case running
    case waitingForUser
    case waitingForAuthorization
    case waitingForReview
    case waitingForExternalEvent
    case paused
    case failed
    case recoveryRequired
    case completed
    case cancelled
}

/// Session 暂停或等待时需要 Host 处理的事项。
///
/// Host 应根据该值展示用户操作入口或执行外部状态查询，不应通过解析错误文本推断下一步。
public enum BoneAgentExecutionAttention: Codable, Equatable, Sendable {
    case userInput(requestID: String)
    case authorization(ticketID: BoneAuthorizationTicketID)
    case review(reviewID: String)
    case externalEvent(eventID: String)
    case recovery(reason: BoneAgentExecutionRecoveryReason)

    private enum CodingKeys: String, CodingKey {
        case kind
        case requestID
        case ticketID
        case reviewID
        case eventID
        case reason
    }

    private enum Kind: String, Codable {
        case userInput
        case authorization
        case review
        case externalEvent
        case recovery
    }

    /// 从持久化数据恢复 Attention，并校验 case 与字段的一致性。
    /// - Parameter decoder: 提供已编码的 Attention 数据。
    /// - Throws: 数据缺少必要字段或包含未知 kind 时抛出解码错误。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .userInput:
            try self.init(userInput: container.decode(String.self, forKey: .requestID))
        case .authorization:
            try self.init(authorization: container.decode(BoneAuthorizationTicketID.self, forKey: .ticketID))
        case .review:
            try self.init(review: container.decode(String.self, forKey: .reviewID))
        case .externalEvent:
            try self.init(externalEvent: container.decode(String.self, forKey: .eventID))
        case .recovery:
            self = .recovery(reason: try container.decode(BoneAgentExecutionRecoveryReason.self, forKey: .reason))
        }
    }

    /// 将 Attention 编码为带有显式 kind 的稳定结构。
    /// - Parameter encoder: 接收编码字段的 Encoder。
    /// - Throws: Encoder 无法写入字段时抛出编码错误。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .userInput(requestID):
            try container.encode(Kind.userInput, forKey: .kind)
            try container.encode(requestID, forKey: .requestID)
        case let .authorization(ticketID):
            try container.encode(Kind.authorization, forKey: .kind)
            try container.encode(ticketID, forKey: .ticketID)
        case let .review(reviewID):
            try container.encode(Kind.review, forKey: .kind)
            try container.encode(reviewID, forKey: .reviewID)
        case let .externalEvent(eventID):
            try container.encode(Kind.externalEvent, forKey: .kind)
            try container.encode(eventID, forKey: .eventID)
        case let .recovery(reason):
            try container.encode(Kind.recovery, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    /// 创建等待用户输入的 Attention。
    /// - Parameter requestID: Host 用于关联输入请求的稳定标识。
    /// - Throws: requestID 为空或过长时抛出 Session 错误。
    public init(userInput requestID: String) throws {
        guard Self.validOpaqueID(requestID) else { throw BoneAgentExecutionSessionError.invalidInput }
        self = .userInput(requestID: requestID)
    }

    /// 创建等待授权的 Attention。
    /// - Parameter ticketID: 一次性授权票据标识。
    /// - Throws: ticketID 不符合 Bone 授权标识约束时抛出 Session 错误。
    public init(authorization ticketID: BoneAuthorizationTicketID) throws {
        self = .authorization(ticketID: ticketID)
    }

    /// 创建等待审核的 Attention。
    /// - Parameter reviewID: Host 用于关联审核记录的稳定标识。
    /// - Throws: reviewID 为空或过长时抛出 Session 错误。
    public init(review reviewID: String) throws {
        guard Self.validOpaqueID(reviewID) else { throw BoneAgentExecutionSessionError.invalidInput }
        self = .review(reviewID: reviewID)
    }

    /// 创建等待外部事件的 Attention。
    /// - Parameter eventID: Host 用于关联外部事件的稳定标识。
    /// - Throws: eventID 为空或过长时抛出 Session 错误。
    public init(externalEvent eventID: String) throws {
        guard Self.validOpaqueID(eventID) else { throw BoneAgentExecutionSessionError.invalidInput }
        self = .externalEvent(eventID: eventID)
    }

    fileprivate static func validOpaqueID(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) ||
                (97...122).contains($0) || [45, 46, 95].contains($0)
        }
    }
}

/// Session 进入恢复态时的稳定原因。
///
/// 原因用于 Host 路由恢复流程和审计，不能被当作普通业务失败重试。
public enum BoneAgentExecutionRecoveryReason: String, Codable, Equatable, Sendable {
    case missingSnapshot
    case snapshotBindingMismatch
    case providerContinuationInvalid
    case toolOutcomeUnknown
    case effectReceiptUnknown
    case leaseConflict
    case configurationDrift
    case persistenceOutcomeUnknown
}

/// Agent Execution Session 的持久化控制面记录。
///
/// 私有会话正文由 `BoneWorkflowAgentExecutionSnapshotStore` 管理，Session 只保存其经过身份、revision 和 lease 绑定的引用。
public struct BoneAgentExecutionSession: Codable, Equatable, Sendable {
    /// 当前 Session 控制面 schema 版本。
    public static let currentSchemaVersion: UInt64 = 1

    public let schemaVersion: UInt64
    public let sessionID: String
    public let runID: BoneRunID
    /// 私有 Conversation 状态的 UUID，恢复时用于防止跨会话快照误绑定。
    public let conversationID: UUID
    /// 恢复时必须重新绑定的模型标识，不包含凭据或 Endpoint。
    public let modelID: String
    /// 恢复时必须匹配的 Provider/本地运行时绑定标识。
    public let bindingID: String
    public let workflowIdentity: String
    public let workflowRevision: UInt64
    public let configurationDigest: String
    public let toolCatalogDigest: String
    public let promptProfileDigest: String?
    public let state: BoneAgentExecutionSessionState
    public let attention: BoneAgentExecutionAttention?
    public let snapshotReference: BoneWorkflowAgentExecutionSnapshotReference?
    public let revision: UInt64
    public let leaseGeneration: UInt64

    /// 创建一个尚未取得执行租约的长期 Session。
    /// - Parameters:
    ///   - sessionID: Host 生成的 Session 稳定标识。
    ///   - runID: 与现有 Workflow Run 绑定的身份。
    ///   - workflowIdentity: 冻结的 Workflow 标识。
    ///   - workflowRevision: 冻结的 Workflow 版本。
    ///   - configurationDigest: Agent 配置和 Provider 绑定的 SHA-256 摘要。
    ///   - toolCatalogDigest: 暴露给模型的 Tool Catalog SHA-256 摘要。
    ///   - promptProfileDigest: 已编译 Prompt Profile 的可选 SHA-256 摘要。
    /// - Returns: revision 为 1、leaseGeneration 为 0、状态为 active 的 Session。
    /// - Throws: 任一身份、版本或摘要不符合持久化合同要求时抛出 Session 错误。
    public init(
        sessionID: String,
        runID: BoneRunID,
        conversationID: UUID,
        modelID: String,
        bindingID: String,
        workflowIdentity: String,
        workflowRevision: UInt64,
        configurationDigest: String,
        toolCatalogDigest: String,
        promptProfileDigest: String? = nil
    ) throws {
        guard Self.validOpaqueID(sessionID),
              Self.validOpaqueID(modelID),
              Self.validOpaqueID(bindingID),
              Self.validOpaqueID(workflowIdentity),
              workflowRevision > 0,
              Self.validDigest(configurationDigest),
              Self.validDigest(toolCatalogDigest),
              promptProfileDigest.map(Self.validDigest) ?? true else {
            throw BoneAgentExecutionSessionError.invalidInput
        }
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            sessionID: sessionID,
            runID: runID,
            conversationID: conversationID,
            modelID: modelID,
            bindingID: bindingID,
            workflowIdentity: workflowIdentity,
            workflowRevision: workflowRevision,
            configurationDigest: configurationDigest,
            toolCatalogDigest: toolCatalogDigest,
            promptProfileDigest: promptProfileDigest,
            state: .active,
            attention: nil,
            snapshotReference: nil,
            revision: 1,
            leaseGeneration: 0
        )
    }

    /// 从可信持久化数据创建已校验的 Session。
    /// - Parameters: 与公开属性同名的持久化字段。
    /// - Returns: 满足全部不变量的 Session。
    /// - Throws: schema、状态、revision、lease、身份或摘要不合法时抛出 Session 错误。
    private init(
        schemaVersion: UInt64,
        sessionID: String,
        runID: BoneRunID,
        conversationID: UUID,
        modelID: String,
        bindingID: String,
        workflowIdentity: String,
        workflowRevision: UInt64,
        configurationDigest: String,
        toolCatalogDigest: String,
        promptProfileDigest: String?,
        state: BoneAgentExecutionSessionState,
        attention: BoneAgentExecutionAttention?,
        snapshotReference: BoneWorkflowAgentExecutionSnapshotReference?,
        revision: UInt64,
        leaseGeneration: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.runID = runID
        self.conversationID = conversationID
        self.modelID = modelID
        self.bindingID = bindingID
        self.workflowIdentity = workflowIdentity
        self.workflowRevision = workflowRevision
        self.configurationDigest = configurationDigest
        self.toolCatalogDigest = toolCatalogDigest
        self.promptProfileDigest = promptProfileDigest
        self.state = state
        self.attention = attention
        self.snapshotReference = snapshotReference
        self.revision = revision
        self.leaseGeneration = leaseGeneration
    }

    /// 从 Codable 数据解码并验证 Session 的全部持久化不变量。
    /// - Parameter decoder: 提供 Session 字段的 Decoder。
    /// - Throws: 数据不完整、schema 未支持或状态不一致时抛出解码错误。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let value = Self(
            schemaVersion: try container.decode(UInt64.self, forKey: .schemaVersion),
            sessionID: try container.decode(String.self, forKey: .sessionID),
            runID: try container.decode(BoneRunID.self, forKey: .runID),
            conversationID: try container.decode(UUID.self, forKey: .conversationID),
            modelID: try container.decode(String.self, forKey: .modelID),
            bindingID: try container.decode(String.self, forKey: .bindingID),
            workflowIdentity: try container.decode(String.self, forKey: .workflowIdentity),
            workflowRevision: try container.decode(UInt64.self, forKey: .workflowRevision),
            configurationDigest: try container.decode(String.self, forKey: .configurationDigest),
            toolCatalogDigest: try container.decode(String.self, forKey: .toolCatalogDigest),
            promptProfileDigest: try container.decodeIfPresent(String.self, forKey: .promptProfileDigest),
            state: try container.decode(BoneAgentExecutionSessionState.self, forKey: .state),
            attention: try container.decodeIfPresent(BoneAgentExecutionAttention.self, forKey: .attention),
            snapshotReference: try container.decodeIfPresent(BoneWorkflowAgentExecutionSnapshotReference.self, forKey: .snapshotReference),
            revision: try container.decode(UInt64.self, forKey: .revision),
            leaseGeneration: try container.decode(UInt64.self, forKey: .leaseGeneration)
        )
        try value.validate()
        self = value
    }

    /// 校验 Session 的身份、状态、Attention、快照和计数关系。
    /// - Returns: 无返回值，校验成功表示可进入 Store。
    /// - Throws: 任一持久化不变量不满足时抛出 Session 错误。
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw BoneAgentExecutionSessionError.unsupportedVersion
        }
        guard Self.validOpaqueID(sessionID),
              Self.validOpaqueID(modelID),
              Self.validOpaqueID(bindingID),
              Self.validOpaqueID(workflowIdentity),
              workflowRevision > 0,
              Self.validDigest(configurationDigest),
              Self.validDigest(toolCatalogDigest),
              promptProfileDigest.map(Self.validDigest) ?? true,
              revision > 0 else {
            throw BoneAgentExecutionSessionError.invalidInput
        }
        guard snapshotReference?.runID == runID || snapshotReference == nil else {
            throw BoneAgentExecutionSessionError.identityMismatch
        }
        // 接管 lease 后仍保留最后一个已确认快照的旧 generation，便于恢复者读取安全边界。
        // 新执行结果必须使用当前 generation 生成新的快照引用后才能提交。
        guard snapshotReference?.leaseGeneration ?? 0 <= leaseGeneration else {
            throw BoneAgentExecutionSessionError.leaseConflict
        }
        try Self.validateAttention(state: state, attention: attention)
    }

    /// 生成带有新状态的 Session，并递增 revision。
    /// - Parameters:
    ///   - next: 目标状态。
    ///   - attention: 目标状态关联的 Attention。等待或恢复状态必须提供匹配的 Attention。
    /// - Returns: 递增 revision 后的 Session。
    /// - Throws: 状态迁移不允许、计数溢出或 Attention 不匹配时抛出 Session 错误。
    public func transitioned(
        to next: BoneAgentExecutionSessionState,
        attention: BoneAgentExecutionAttention? = nil
    ) throws -> Self {
        guard state != next else { throw BoneAgentExecutionSessionError.invalidTransition }
        guard Self.allowedTransitions[state, default: []].contains(next) else {
            throw BoneAgentExecutionSessionError.invalidTransition
        }
        let nextRevision = try Self.increment(revision)
        let updated = Self(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            runID: runID,
            conversationID: conversationID,
            modelID: modelID,
            bindingID: bindingID,
            workflowIdentity: workflowIdentity,
            workflowRevision: workflowRevision,
            configurationDigest: configurationDigest,
            toolCatalogDigest: toolCatalogDigest,
            promptProfileDigest: promptProfileDigest,
            state: next,
            attention: attention,
            snapshotReference: snapshotReference,
            revision: nextRevision,
            leaseGeneration: leaseGeneration
        )
        try updated.validate()
        return updated
    }

    /// 为 Session 获取下一代执行租约。
    /// - Returns: leaseGeneration 加一、revision 加一的 Session。
    /// - Throws: Session 已终止、已进入恢复态或计数溢出时抛出 Session 错误。
    public func acquiringLease() throws -> Self {
        guard !Self.terminalStates.contains(state), state != .recoveryRequired else {
            throw BoneAgentExecutionSessionError.terminalState
        }
        let (nextLease, leaseOverflow) = leaseGeneration.addingReportingOverflow(1)
        guard !leaseOverflow else { throw BoneAgentExecutionSessionError.counterOverflow }
        let updated = Self(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            runID: runID,
            conversationID: conversationID,
            modelID: modelID,
            bindingID: bindingID,
            workflowIdentity: workflowIdentity,
            workflowRevision: workflowRevision,
            configurationDigest: configurationDigest,
            toolCatalogDigest: toolCatalogDigest,
            promptProfileDigest: promptProfileDigest,
            state: state,
            attention: attention,
            snapshotReference: snapshotReference,
            revision: try Self.increment(revision),
            leaseGeneration: nextLease
        )
        try updated.validate()
        return updated
    }

    /// 绑定新的 Host-owned 执行快照引用。
    /// - Parameter reference: 与当前 Run、lease 和下一次持久化版本匹配的快照引用。
    /// - Returns: revision 加一并绑定快照引用的 Session。
    /// - Throws: 快照身份或 lease 与 Session 不匹配时抛出 Session 错误。
    public func binding(snapshot reference: BoneWorkflowAgentExecutionSnapshotReference) throws -> Self {
        guard reference.runID == runID,
              reference.leaseGeneration == leaseGeneration,
              leaseGeneration > 0 else {
            throw BoneAgentExecutionSessionError.leaseConflict
        }
        let updated = Self(
            schemaVersion: schemaVersion,
            sessionID: sessionID,
            runID: runID,
            conversationID: conversationID,
            modelID: modelID,
            bindingID: bindingID,
            workflowIdentity: workflowIdentity,
            workflowRevision: workflowRevision,
            configurationDigest: configurationDigest,
            toolCatalogDigest: toolCatalogDigest,
            promptProfileDigest: promptProfileDigest,
            state: state,
            attention: attention,
            snapshotReference: reference,
            revision: try Self.increment(revision),
            leaseGeneration: leaseGeneration
        )
        try updated.validate()
        return updated
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case sessionID
        case runID
        case conversationID
        case modelID
        case bindingID
        case workflowIdentity
        case workflowRevision
        case configurationDigest
        case toolCatalogDigest
        case promptProfileDigest
        case state
        case attention
        case snapshotReference
        case revision
        case leaseGeneration
    }

    private static let terminalStates: Set<BoneAgentExecutionSessionState> = [.failed, .recoveryRequired, .completed, .cancelled]

    private static let allowedTransitions: [BoneAgentExecutionSessionState: Set<BoneAgentExecutionSessionState>] = [
        .active: [.running, .waitingForUser, .waitingForAuthorization, .waitingForReview, .waitingForExternalEvent, .paused, .recoveryRequired, .cancelled],
        .running: [.active, .waitingForUser, .waitingForAuthorization, .waitingForReview, .waitingForExternalEvent, .paused, .failed, .recoveryRequired, .completed, .cancelled],
        .waitingForUser: [.active, .running, .paused, .failed, .recoveryRequired, .cancelled],
        .waitingForAuthorization: [.active, .running, .paused, .failed, .recoveryRequired, .cancelled],
        .waitingForReview: [.active, .running, .paused, .failed, .recoveryRequired, .cancelled],
        .waitingForExternalEvent: [.active, .running, .paused, .failed, .recoveryRequired, .cancelled],
        .paused: [.active, .running, .failed, .recoveryRequired, .cancelled],
        .failed: [],
        .recoveryRequired: [],
        .completed: [],
        .cancelled: []
    ]

    private static func validateAttention(state: BoneAgentExecutionSessionState, attention: BoneAgentExecutionAttention?) throws {
        switch state {
        case .waitingForUser:
            guard case .userInput = attention else { throw BoneAgentExecutionSessionError.attentionMismatch }
        case .waitingForAuthorization:
            guard case .authorization = attention else { throw BoneAgentExecutionSessionError.attentionMismatch }
        case .waitingForReview:
            guard case .review = attention else { throw BoneAgentExecutionSessionError.attentionMismatch }
        case .waitingForExternalEvent:
            guard case .externalEvent = attention else { throw BoneAgentExecutionSessionError.attentionMismatch }
        case .recoveryRequired:
            guard case .recovery = attention else { throw BoneAgentExecutionSessionError.attentionMismatch }
        default:
            guard attention == nil else { throw BoneAgentExecutionSessionError.attentionMismatch }
        }
    }

    private static func validOpaqueID(_ value: String) -> Bool {
        BoneAgentExecutionAttention.validOpaqueID(value)
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func increment(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw BoneAgentExecutionSessionError.counterOverflow }
        return next
    }
}

/// Agent Execution Session 控制面错误。
public enum BoneAgentExecutionSessionError: Error, Codable, Equatable, Sendable {
    case invalidInput
    case unsupportedVersion
    case invalidTransition
    case attentionMismatch
    case identityMismatch
    case revisionConflict
    case leaseConflict
    case terminalState
    case missingSession
    case identityReused
    case persistenceCapabilityUnavailable
    case counterOverflow
}
