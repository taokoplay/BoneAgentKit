import Foundation
import BoneAgentKit
import BoneAgentTools

struct DemoToolAuthorizationRequest: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
}

/// PDF 密码请求只携带展示文案和一次性请求身份，不携带资源正文或历史密码。
struct DemoPDFPasswordRequest: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
}

struct DemoToolInteractionHandlers: Sendable {
    let ask: @Sendable (BoneUserQuestion) async throws -> BoneUserAnswer
    let authorize: @Sendable (DemoToolAuthorizationRequest) async throws -> Bool
    /// 在 PDF 受保护时临时获取密码，返回值只允许留在当前工具调用内存中。
    let requestPDFPassword: @Sendable (DemoPDFPasswordRequest) async throws -> String

    /// 保留旧调用方只传 ask 和 authorize 时的初始化兼容性。
    init(ask: @escaping @Sendable (BoneUserQuestion) async throws -> BoneUserAnswer,
         authorize: @escaping @Sendable (DemoToolAuthorizationRequest) async throws -> Bool,
         requestPDFPassword: @escaping @Sendable (DemoPDFPasswordRequest) async throws -> String = { _ in
             throw BoneAskUserError.unavailable
         }) {
        self.ask = ask
        self.authorize = authorize
        self.requestPDFPassword = requestPDFPassword
    }

    static let unavailable = Self(ask: { _ in throw BoneAskUserError.unavailable },
                                  authorize: { _ in throw BoneAuthorizationError.denied },
                                  requestPDFPassword: { _ in throw BoneAskUserError.unavailable })
}

/// A private, bounded, process-local Host ledger for Conversation tools.
/// It is not durable Workflow persistence. Interrupted chat archives prohibit replay across processes.
actor DemoToolEffectStore: BoneWorkflowEffectStore {
    private struct Record {
        let grant: BoneAuthorizationGrant
        var intent: BoneEffectIntent?
        var receipt: BoneEffectReceipt?
        var cancelled = false
        var committed = false
        var unknown = false
    }
    private var records: [BoneEffectID: Record] = [:]
    private let networkConsent = DemoNetworkConsent()
    private var activeRunID: UUID?
    private var consentEpoch = UUID()
    private let clock: @Sendable () -> TimeInterval
    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.clock = clock }

    func beginRun(scope: DemoNetworkConsent.Scope) async -> UUID {
        let id = UUID()
        activeRunID = id; consentEpoch = id
        await networkConsent.begin(scope: scope, id: id)
        return id
    }

    @discardableResult
    func endRun(id: UUID) async -> Int {
        guard activeRunID == id else { return 0 }
        activeRunID = nil
        return await networkConsent.end(id: id)
    }

    func context(for call: BoneInferenceToolCall, definition: BoneAgentToolDefinition,
                 handlers: DemoToolInteractionHandlers, searchProvider: String = "Brave Search",
                 webPolicy: BoneWebHostPolicy? = nil, searchConfiguration: DemoSearchConfiguration? = nil,
                 failureObserver: @escaping DemoToolFailureObserver = { _ in }) async throws -> BoneWorkflowToolExecutionContext? {
        do {
            return try await authorizedContext(for: call, definition: definition, handlers: handlers,
                searchProvider: searchProvider, webPolicy: webPolicy, searchConfiguration: searchConfiguration)
        } catch {
            if let failure = DemoToolFailure.classify(error, toolID: definition.id) { await failureObserver(failure) }
            throw error
        }
    }

    private func authorizedContext(for call: BoneInferenceToolCall, definition: BoneAgentToolDefinition,
                 handlers: DemoToolInteractionHandlers, searchProvider: String,
                 webPolicy: BoneWebHostPolicy?, searchConfiguration: DemoSearchConfiguration?) async throws -> BoneWorkflowToolExecutionContext? {
        try Task.checkCancellation()
        let runID = activeRunID
        let epoch = consentEpoch
        let impact = try definition.requiredImpact()
        try DemoBuiltInToolAssembly.validateLocalInput(call, definition: definition)
        guard !impact.isLocalReadOnly else { return nil }
        guard records.count < 128, let schemaVersion = definition.schemaVersion else {
            throw BoneAuthorizationError.denied
        }
        let requiresApproval = try DemoBuiltInToolAssembly.requiresExplicitApproval(call, definition: definition)
        guard requiresApproval || definition.impact?.dataAccess == .userPrivate else {
            throw BoneAuthorizationError.denied
        }
        let canonical = try BoneCanonicalToolCall(toolID: definition.id, toolVersion: definition.version,
                                                  schemaVersion: schemaVersion, arguments: call.arguments)
        // Asking is itself the selected user interaction. It never approves another tool.
        if requiresApproval && definition.id != "user.ask" && definition.id != "calendar.manage" && definition.id != "reminder.manage" && definition.id != "notification.manage" && definition.id != "photo.manage" && definition.id != "contact.manage" && definition.id != "share.present" && definition.id != "compose.present" {
            // Validate the exact typed input and Host policy before presenting consent.
            let value: String
            var webHost: String?
            if definition.id == "web.fetch" {
                let input = try JSONDecoder().decode(BoneWebFetchInput.self, from: call.arguments)
                guard let webPolicy else { throw BoneWebError.invalidConfiguration }
                webHost = try DemoWebFetchNavigationPolicy.validate(url: input.url, policy: webPolicy).host
                value = input.url
            } else {
                let input = try JSONDecoder().decode(BoneWebSearchInput.self, from: call.arguments)
                if let searchConfiguration {
                    guard searchConfiguration.automaticEnabled else { throw DemoSearchError.disabled }
                    if searchConfiguration.automaticChannel == .deepSeek {
                        guard input.query.unicodeScalars.count <= 128 else { throw DemoSearchError.invalidQuery }
                        guard input.page == 0 else { throw DemoSearchError.unsupportedPage }
                    }
                    if searchConfiguration.automaticChannel == .baiduWeb {
                        _ = try DemoSearchQuery(input.query)
                        guard input.page == 0 else { throw DemoBrowserSearchError.unsupportedPage }
                    }
                }
                value = input.query
            }
            guard !value.isEmpty, value.utf8.count <= 4_096 else { throw BoneWebError.invalidInput }
            try await networkConsent.authorize(tool: definition.id == "web.fetch" ? .webFetch : .webSearch,
                target: value, webHost: webHost, fallbackTitle: definition.title,
                searchProvider: searchProvider, handlers: handlers)
        }
        if requiresApproval && ["calendar.manage", "reminder.manage", "notification.manage", "photo.manage", "contact.manage", "share.present", "compose.present"].contains(definition.id) {
            guard try await handlers.authorize(.init(id: UUID(), title: definition.title,
                detail: try appleAuthorizationDetail(call, definition: definition))) else {
                throw BoneAuthorizationError.denied
            }
        }
        try Task.checkCancellation()
        guard activeRunID == runID, consentEpoch == epoch else { throw CancellationError() }
        guard records.count < 128 else { throw BoneAuthorizationError.denied }
        let now = clock()
        let context = try BoneWorkflowToolExecutionContext(ticketID: .init(UUID().uuidString),
            runID: .init(UUID().uuidString), stepID: .init("conversation-tool"), attemptID: .init(UUID().uuidString),
            toolCallID: .init(call.id), effectID: .init(UUID().uuidString), principal: "agent-lab-user",
            resourceScope: canonical.argumentsDigest, resourceRevision: 1, authorizationNonce: UUID().uuidString,
            nowUptime: now, leaseGeneration: 1, recoveryStrategy: .nonRecoverableRequiresUserDecision, idempotencyKey: nil)
        let grant = try BoneAuthorizationGrant(ticketID: context.ticketID, runID: context.runID,
            stepID: context.stepID, attemptID: context.attemptID, toolCallID: context.toolCallID,
            canonicalCall: canonical, principal: context.principal, resourceScope: context.resourceScope,
            resourceRevision: context.resourceRevision, impact: impact, grantedAtUptime: now,
            expiresAtUptime: now + 15, nonce: context.authorizationNonce)
        records[context.effectID] = .init(grant: grant)
        return context
    }

    /// 生成 Apple 写操作的最小确认预览，避免把图片正文、密码或完整私有资源写入日志。
    /// - Parameters:
    ///   - call: 模型提交的原始工具调用。
    ///   - definition: 已注册的 Apple 工具定义。
    /// - Returns: 展示给用户的有界确认文案。
    private func appleAuthorizationDetail(_ call: BoneInferenceToolCall, definition: BoneAgentToolDefinition) throws -> String {
        let decoder = JSONDecoder()
        switch definition.id {
        case "calendar.manage":
            let input = try decoder.decode(BoneCalendarRequest.self, from: call.arguments)
            switch input.action {
            case .create:
                return "将创建日历事件「\(input.title ?? "")」，时间为 \(input.startDate ?? "") 至 \(input.endDate ?? "")。确认后写入系统日历。"
            case .update:
                return "将修改日历事件 \(input.identifier ?? "")。确认后写入系统日历。"
            case .delete:
                return "将删除日历事件 \(input.identifier ?? "")。确认后从系统日历移除。"
            case .search, .get:
                return "当前操作不会写入系统日历。"
            }
        case "reminder.manage":
            let input = try decoder.decode(BoneReminderRequest.self, from: call.arguments)
            switch input.action {
            case .create:
                return "将创建提醒「\(input.title ?? "")」，到期时间为 \(input.dueDate ?? "未设置")。确认后写入提醒事项。"
            case .update:
                return "将修改提醒 \(input.identifier ?? "")。确认后写入提醒事项。"
            case .complete:
                return "将完成提醒 \(input.identifier ?? "")。确认后写入提醒事项。"
            case .delete:
                return "将删除提醒 \(input.identifier ?? "")。确认后从提醒事项移除。"
            case .search:
                return "当前操作不会写入提醒事项。"
            }
        case "notification.manage":
            let input = try decoder.decode(BoneNotificationRequest.self, from: call.arguments)
            switch input.action {
            case .schedule:
                return "将安排本 App 的本地通知「\(input.title ?? "")」，时间为 \(input.fireDate ?? "")。确认后提交系统通知。"
            case .cancel:
                return "将取消本 App 安排的本地通知 \(input.identifier ?? "")。"
            case .list:
                return "当前操作不会修改本地通知。"
            }
        case "photo.manage":
            let input = try decoder.decode(BonePhotoRequest.self, from: call.arguments)
            return "将把已登记图片 \(input.imageID) 保存到系统相册\(input.albumTitle.map { "「\($0)」" } ?? "")。确认后写入相册。"
        case "contact.manage":
            let input = try decoder.decode(BoneContactRequest.self, from: call.arguments)
            switch input.action {
            case .create:
                return "将创建联系人「\(input.familyName ?? "")\(input.givenName ?? "")」，确认后写入系统通讯录。"
            case .update:
                return "将修改联系人 \(input.identifier ?? "") 的已提供字段，确认后写入系统通讯录。"
            case .delete:
                return "将删除联系人 \(input.identifier ?? "")，确认后从系统通讯录移除。"
            case .search, .get:
                return "当前操作不会写入系统通讯录。"
            }
        case "share.present":
            let input = try decoder.decode(BoneShareRequest.self, from: call.arguments)
            return "将打开系统分享面板，内容类型为 \(input.contentType.rawValue)。确认后交给你选择分享目标。"
        case "compose.present":
            let input = try decoder.decode(BoneComposeRequest.self, from: call.arguments)
            return "将打开 \(input.channel == .mail ? "邮件" : "信息") 编辑器，收件人数量为 \(input.recipients.count)。确认后由你检查和发送。"
        default:
            return "请核对本次系统操作的内容和目标。确认后才会写入系统数据。"
        }
    }

    func consumeAuthorizationAndPersistIntent(_ value: BoneAuthorizationValidation, intent: BoneEffectIntent) throws {
        guard var record = records[intent.id], record.intent == nil else { throw BoneAuthorizationError.alreadyConsumed }
        let grant = record.grant
        let now = clock()
        guard now.isFinite, now >= grant.grantedAtUptime, now <= grant.expiresAtUptime,
              value.nowUptime >= grant.grantedAtUptime, value.nowUptime <= grant.expiresAtUptime else {
            throw BoneAuthorizationError.expired
        }
        guard value.ticketID == grant.ticketID, value.runID == grant.runID, value.stepID == grant.stepID,
              value.attemptID == grant.attemptID, value.toolCallID == grant.toolCallID,
              value.canonicalCall == grant.canonicalCall, value.principal == grant.principal,
              value.resourceScope == grant.resourceScope, value.resourceRevision == grant.resourceRevision,
              value.impact == grant.impact, value.nonce == grant.nonce,
              intent.runID == value.runID, intent.stepID == value.stepID, intent.attemptID == value.attemptID,
              intent.toolCallID == value.toolCallID, intent.argumentsDigest == value.canonicalCall.argumentsDigest,
              intent.phase == .intentPersisted, intent.leaseGeneration == 1 else { throw BoneAuthorizationError.bindingMismatch }
        record.intent = intent
        records[intent.id] = record
    }

    func persistCancellation(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        var record = try checked(effectID, leaseGeneration)
        guard record.intent?.phase == .intentPersisted, !record.committed else { throw BoneWorkflowToolExecutionError.effectStoreRejected }
        record.cancelled = true; records[effectID] = record
    }
    func markExecutionStarted(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        var record = try checked(effectID, leaseGeneration)
        guard let old = record.intent, old.phase == .intentPersisted, !record.cancelled else {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
        record.intent = try .init(id: old.id, sessionID: old.sessionID, runID: old.runID, stepID: old.stepID, attemptID: old.attemptID,
            toolCallID: old.toolCallID, recoveryStrategy: old.recoveryStrategy, idempotencyKey: old.idempotencyKey,
            idempotencyKeyDigest: old.idempotencyKeyDigest, argumentsDigest: old.argumentsDigest,
            phase: .executionStarted, leaseGeneration: leaseGeneration)
        records[effectID] = record
    }
    func recordReceipt(_ receipt: BoneEffectReceipt) throws {
        var record = try checked(receipt.effectID, receipt.leaseGeneration)
        guard record.intent?.phase == .executionStarted, record.receipt == nil, !record.unknown,
              !record.cancelled, !record.committed else { throw BoneWorkflowToolExecutionError.effectStoreRejected }
        record.receipt = receipt; records[receipt.effectID] = record
    }
    func commitReceipt(effectID: BoneEffectID, leaseGeneration: UInt64) throws {
        var record = try checked(effectID, leaseGeneration)
        guard record.receipt != nil, !record.cancelled, !record.unknown, !record.committed else {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
        // Commit the call receipt and session-local checkpoint fact atomically within this actor.
        record.committed = true; records[effectID] = record
    }
    func recoverySnapshot(effectID: BoneEffectID, currentLeaseGeneration: UInt64) throws -> BoneEffectRecoverySnapshot? {
        guard let record = records[effectID] else { return nil }
        _ = try checked(effectID, currentLeaseGeneration)
        guard let intent = record.intent else { return nil }
        return .init(intent: intent, receipt: record.receipt, stepCommitted: record.committed,
                     cancellationPersisted: record.cancelled)
    }
    func persistOutcomeUnknown(effectID: BoneEffectID, currentLeaseGeneration: UInt64) throws {
        var record = try checked(effectID, currentLeaseGeneration)
        guard record.intent?.phase == .executionStarted, record.receipt == nil else {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
        record.unknown = true; records[effectID] = record
    }
    // This chat Host never takes over or replays effects. Recovery requires a new conversation.
    func resumePreparedEffect(effectID: BoneEffectID, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        throw BoneWorkflowToolExecutionError.pipelineUnavailable
    }
    func commitRecoveredReceipt(effectID: BoneEffectID, receiptLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        throw BoneWorkflowToolExecutionError.pipelineUnavailable
    }
    func recordRecoveredReceipt(_ receipt: BoneEffectReceipt, expectedExecutionLeaseGeneration: UInt64, currentLeaseGeneration: UInt64) throws {
        throw BoneWorkflowToolExecutionError.pipelineUnavailable
    }
    private func checked(_ id: BoneEffectID, _ generation: UInt64) throws -> Record {
        guard generation == 1, let record = records[id], record.intent?.leaseGeneration == generation else {
            throw BoneWorkflowToolExecutionError.effectStoreRejected
        }
        return record
    }
}
