import Foundation
import CryptoKit
import BoneAgentKit

/// This Host is private to the example. A single instance owns one frozen Run,
/// its worker and its private text for this process only.
actor DemoLiveWorkflow {
    static let maximumPromptBytes = 16_384
    static let maximumInferenceCalls = 6
    static let maximumToolCalls = 8
    static let maximumInputBytes = 512 * 1_024
    static let maximumOutputBytes = 256 * 1_024
    static let maximumWallClockSeconds: TimeInterval = 120

    private let settings: DemoLiveChatSettings
    private let engine: any BoneInferenceEngine
    private let persistence: DemoLiveWorkflowPersistence
    private let content = DemoLiveWorkflowPrivateContent()
    private var runner: DemoWorkflowRunner?
    private var runID: BoneRunID?
    private let recoverableSessionStore: DemoRecoverableAgentSessionStore
    private var recoverableSessionCoordinator: BoneAgentExecutionSessionCoordinator?
    private var recoverableSessionID: String?
    /// 防止可恢复 Session 的创建、等待和恢复操作在 await 边界重入。
    private var recoverableOperationInFlight = false
    private var isDriving = false
    private var failure: DemoLiveWorkflowFailure?

    private init(settings: DemoLiveChatSettings, engine: any BoneInferenceEngine,
                 persistence: any BoneWorkflowPersistence) {
        self.settings = settings
        self.engine = engine
        self.persistence = DemoLiveWorkflowPersistence(storage: persistence)
        self.recoverableSessionStore = DemoRecoverableAgentSessionStore()
    }

    /// Call only in response to Run. Assembly does not send a model request.
    /// The caller supplies the key; this Host never reads a credential store.
    static func make(settings: DemoLiveChatSettings, apiKey: String,
                     transport: (any BoneInferenceHTTPTransport)? = nil) throws -> DemoLiveWorkflow {
        let settings = try settings.validated()
        let provider = try settings.providerConfiguration(apiKey: apiKey)
        let transport = transport ?? boundedTransport()
        return try make(settings: settings,
                        engine: BoneAgentProviderFactory.makeEngine(configuration: provider, transport: transport))
    }

    /// Explicit injection for offline tests. Failure never falls back to a live engine.
    static func make(settings: DemoLiveChatSettings, engine: any BoneInferenceEngine,
                     persistence: any BoneWorkflowPersistence = BoneInMemoryWorkflowPersistence()) throws -> DemoLiveWorkflow {
        DemoLiveWorkflow(settings: try settings.validated(), engine: engine, persistence: persistence)
    }

    func start(prompt: String, mode: DemoRunMode) async throws -> DemoLiveWorkflowInspection {
        guard !isDriving else { throw DemoLiveWorkflowFailure.busy }
        guard runID == nil else { throw DemoLiveWorkflowFailure.alreadyStarted }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= Self.maximumPromptBytes else { throw DemoLiveWorkflowFailure.invalidPrompt }
        try Task.checkCancellation()
        isDriving = true
        defer { isDriving = false }

        let id = try BoneRunID("live-\(UUID().uuidString)")
        let input = DemoInputReference(id: "private-input-\(UUID().uuidString)", revision: 1)
        let tools: [BoneAnyAgentTool] = settings.enablesCalculator ? [BoneAnyAgentTool(DemoCalculatorTool())] : []
        let capabilities = try DemoCapabilities(policyID: "demo.live.read-only.v1",
                                                allowedToolIDs: tools.map { $0.definition.id })
        var messages: [BoneInferenceMessage] = []
        if !settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(.init(role: .system, content: settings.systemPrompt))
        }
        messages.append(.init(role: .user, content: prompt))
        if let profile = settings.promptProfile {
            messages = try profile.compose(messages: messages)
        }
        let executor = try DemoLiveWorkflowExecutor.make(
            engine: engine, modelID: settings.modelID, maximumOutputTokens: settings.maximumOutputTokens,
            tools: tools, messages: messages, input: input,
            retainOutput: { [content] output in await content.retain(output) }
        )
        let runner = DemoWorkflowRunner(persistence: persistence, executors: try .init([executor]),
                                        capabilities: capabilities)
        self.runner = runner
        runID = id // A second start on this Host never creates another inference attempt.
        await content.retainPrompt(prompt)
        do {
            let report = try await runner.start(runID: id, plan: Self.plan(), mode: mode, input: input)
            if report.outcome == .failed { failure = .executionFailed }
            if report.outcome == .cancelled { failure = .cancelled }
            if report.outcome == .requiresRecovery { failure = .recoveryRequired }
        } catch {
            failure = Self.safeFailure(error)
            // Re-read only. A throwing commit may already have changed the store.
            if let inspection = try? await inspect() { return inspection }
            throw failure ?? .executionFailed
        }
        guard let inspection = try await inspect() else { throw DemoLiveWorkflowFailure.noCheckpoint }
        return inspection
    }

    /// Pure inspection: no lease acquisition, model request or automatic recovery.
    func inspect() async throws -> DemoLiveWorkflowInspection? {
        guard let runID else { return nil }
        let snapshot = try await persistence.load(runID: runID)
        let checkpoint = try DemoCheckpoint.decode(snapshot)
        let compatibility = snapshot.checkpoint.descriptor.compatibility(
            with: try Self.plan(), supportedFormatVersions: [1])
        let recovery = try recoveryAction(snapshot: snapshot, checkpoint: checkpoint, compatibility: compatibility)
        return .init(snapshot: snapshot, checkpoint: checkpoint, evidence: await persistence.evidence(),
                     compatibility: compatibility, recovery: recovery, failure: failure)
    }

    /// Only closes a confirmed terminal Step. It never resumes an inference loop.
    /// Ownership here means this same process-local Host, with no active worker.
    func closeConfirmedStep(expectedRevision: UInt64) async throws -> DemoLiveWorkflowInspection {
        guard !isDriving else { throw DemoLiveWorkflowFailure.busy }
        isDriving = true
        defer { isDriving = false }
        guard let runner, let runID, let inspection = try await inspect(),
              inspection.snapshot.run.revision == expectedRevision else {
            throw BoneWorkflowFailure.revisionConflict
        }
        guard inspection.recovery == .closeConfirmedStep else { throw DemoLiveWorkflowFailure.unsafeRecovery }
        // The runner re-loads and rechecks the revision, frozen scope and dispatch phase.
        // A settled Step takes its closure-only path, returning no reconstructed output.
        do {
            _ = try await runner.resume(runID: runID, expectedRevision: expectedRevision, takeoverAuthorized: true)
            failure = nil
        } catch {
            failure = Self.safeFailure(error)
            throw failure ?? .recoveryRequired
        }
        guard let result = try await inspect() else { throw DemoLiveWorkflowFailure.noCheckpoint }
        return result
    }

    func finalResponse() async -> String? { await content.response() }

    /// 创建只保存控制面和私有快照的可恢复 Agent Session，不发起模型请求。
    /// - Returns: 已取得初始 lease 并保存空 Conversation 快照的 Session 检查结果。
    /// - Throws: Demo 当前配置无法构造 Agent、Session 绑定或联合持久化失败时抛出错误。
    func createRecoverableSession() async throws -> DemoRecoverableAgentSessionInspection {
        try beginRecoverableOperation()
        defer { recoverableOperationInFlight = false }
        guard recoverableSessionCoordinator == nil else { throw DemoLiveWorkflowFailure.alreadyStarted }
        let assembly = try await makeRecoverableAgentAssembly()
        let sessionID = "demo-session-\(UUID().uuidString)"
        let session = try BoneAgentExecutionSession(
            sessionID: sessionID,
            runID: try BoneRunID("demo-session-run-\(UUID().uuidString)"),
            conversationID: await assembly.conversation.id,
            modelID: settings.modelID,
            bindingID: assembly.bindingID,
            workflowIdentity: assembly.binding.workflowIdentity,
            workflowRevision: assembly.binding.workflowRevision,
            configurationDigest: assembly.binding.configurationDigest,
            toolCatalogDigest: assembly.binding.toolCatalogDigest,
            promptProfileDigest: assembly.binding.promptProfileDigest
        )
        let coordinator = BoneAgentExecutionSessionCoordinator(
            agent: assembly.agent,
            sessionStore: recoverableSessionStore,
            snapshotStore: recoverableSessionStore,
            binding: assembly.binding
        )
        let started = try await coordinator.start(
            session: session,
            conversation: assembly.conversation,
            stepID: .init("demo-session-step"),
            attemptID: .init("demo-session-attempt")
        )
        recoverableSessionCoordinator = coordinator
        recoverableSessionID = sessionID
        return .init(session: started, output: nil)
    }

    /// 恢复可恢复 Session 并发送一轮用户输入。
    /// - Parameter userMessage: 本轮交给已恢复 Conversation 的用户输入。
    /// - Returns: 模型成功完成后保存的新 Session 和本轮输出。
    /// - Throws: Session 未创建、恢复边界无效、配置漂移或模型执行失败时抛出错误。
    func runRecoverableSession(userMessage: String) async throws -> DemoRecoverableAgentSessionInspection {
        try beginRecoverableOperation()
        defer { recoverableOperationInFlight = false }
        return try await runRecoverableSessionUnchecked(userMessage: userMessage)
    }

    /// 在已持有可恢复操作门禁时执行一轮模型调用。
    /// - Parameter userMessage: 本轮交给已恢复 Conversation 的用户输入。
    /// - Returns: 模型成功完成后保存的新 Session 和本轮输出。
    /// - Throws: Session 未创建、恢复边界无效、配置漂移或模型执行失败时抛出错误。
    private func runRecoverableSessionUnchecked(userMessage: String) async throws -> DemoRecoverableAgentSessionInspection {
        guard let coordinator = recoverableSessionCoordinator,
              let sessionID = recoverableSessionID else {
            throw DemoLiveWorkflowFailure.noCheckpoint
        }
        let result = try await coordinator.run(sessionID: sessionID, userMessage: userMessage)
        let session = try await coordinator.load(sessionID: sessionID)
        return .init(session: session, output: result.output)
    }

    /// 将可恢复 Session 置为等待用户状态，不会发起模型请求。
    /// - Parameter requestID: Host 用于关联用户输入的稳定请求标识。
    /// - Returns: 已确认进入 waitingForUser 的 Session 检查结果。
    func waitForRecoverableSessionUser(requestID: String) async throws -> DemoRecoverableAgentSessionInspection {
        try beginRecoverableOperation()
        defer { recoverableOperationInFlight = false }
        guard let coordinator = recoverableSessionCoordinator,
              let sessionID = recoverableSessionID else {
            throw DemoLiveWorkflowFailure.noCheckpoint
        }
        let session = try await coordinator.waitForUser(sessionID: sessionID, requestID: requestID)
        return .init(session: session, output: nil)
    }

    /// 恢复等待用户的 Session，并发送用户确认后的下一轮输入。
    /// - Parameter userMessage: 用户确认后交给模型的下一轮输入。
    /// - Returns: 模型成功完成后保存的新 Session 和本轮输出。
    /// - Throws: Session 未处于等待用户状态或恢复边界无法确认时抛出错误。
    func resumeRecoverableSession(userMessage: String) async throws -> DemoRecoverableAgentSessionInspection {
        try beginRecoverableOperation()
        defer { recoverableOperationInFlight = false }
        guard let coordinator = recoverableSessionCoordinator,
              let sessionID = recoverableSessionID else {
            throw DemoLiveWorkflowFailure.noCheckpoint
        }
        let current = try await coordinator.load(sessionID: sessionID)
        guard current.state == .waitingForUser else { throw DemoLiveWorkflowFailure.unsafeRecovery }
        _ = try await coordinator.resume(sessionID: sessionID)
        return try await runRecoverableSessionUnchecked(userMessage: userMessage)
    }

    /// 读取当前可恢复 Session 的控制面状态，不触发恢复或模型请求。
    /// - Returns: 当前 Session 检查结果，尚未创建时返回 nil。
    func inspectRecoverableSession() async throws -> DemoRecoverableAgentSessionInspection? {
        guard let coordinator = recoverableSessionCoordinator,
              let sessionID = recoverableSessionID else { return nil }
        return .init(session: try await coordinator.load(sessionID: sessionID), output: nil)
    }

    /// 取得可恢复操作的单一所有权，避免 Actor 在异步等待期间接受第二个写操作。
    /// - Throws: 已有创建、等待或恢复操作进行时抛出 busy。
    private func beginRecoverableOperation() throws {
        guard !recoverableOperationInFlight else { throw DemoLiveWorkflowFailure.busy }
        recoverableOperationInFlight = true
    }

    /// 构造 Demo 专用的 Agent、Conversation 和持久化绑定。
    /// - Returns: 可交给 Session Coordinator 的 Demo Agent 装配结果。
    /// - Throws: Tool、Prompt Profile、模型能力或摘要编码不满足约束时抛出错误。
    private func makeRecoverableAgentAssembly() async throws -> DemoRecoverableAgentAssembly {
        let tools: [BoneAnyAgentTool] = settings.enablesCalculator ? [BoneAnyAgentTool(DemoCalculatorTool())] : []
        let registry = try BoneAgentToolRegistry(tools: tools)
        let policy = BoneToolImpactPolicy(maximumAllowed: .ordinaryPublicRead)
        let budget = try BoneRunBudget(
            maximumInferenceCalls: Self.maximumInferenceCalls,
            maximumToolCalls: Self.maximumToolCalls,
            maximumInputBytes: Self.maximumInputBytes,
            maximumOutputBytes: Self.maximumOutputBytes,
            maximumTurns: Self.maximumInferenceCalls,
            maximumWallClockSeconds: Self.maximumWallClockSeconds,
            maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: Int64.max
        )
        let configuration = try BoneAgentConfiguration(
            maximumSteps: Self.maximumInferenceCalls,
            runBudget: budget,
            toolImpactPolicy: policy,
            inferenceCostEstimator: { _ in 0 },
            logging: .init(logger: DemoLiveWorkflowSilentLogger(), includesSensitivePayloads: false)
        )
        let modelEngine = DemoLiveWorkflowModelEngine(
            engine: engine,
            modelID: settings.modelID,
            maximumOutputTokens: settings.maximumOutputTokens
        )
        let agent = BoneAgent(
            inferenceEngine: modelEngine,
            toolRegistry: registry,
            toolContext: BoneAgentEmptyContext(),
            configuration: configuration
        )
        var systemMessages: [BoneInferenceMessage] = []
        if !settings.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            systemMessages.append(.init(role: .system, content: settings.systemPrompt))
        }
        let bindingID = "demo-provider-\(settings.provider.rawValue)"
        let conversation = try await agent.makeConversation(
            modelID: settings.modelID,
            bindingID: bindingID,
            systemMessages: systemMessages,
            promptProfile: settings.promptProfile
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let configurationDigest = DemoRecoverableAgentDigest.hex(try encoder.encode(settings))
        let toolCatalogDigest = DemoRecoverableAgentDigest.hex(try encoder.encode(registry.definitions))
        let promptProfileDigest = try settings.promptProfile.map { DemoRecoverableAgentDigest.hex(try encoder.encode($0)) }
        let binding = try BoneAgentExecutionSessionBinding(
            workflowIdentity: "demo.recoverable-agent-session",
            workflowRevision: 1,
            configurationDigest: configurationDigest,
            toolCatalogDigest: toolCatalogDigest,
            promptProfileDigest: promptProfileDigest
        )
        return .init(agent: agent, conversation: conversation, binding: binding, bindingID: bindingID)
    }

    static func plan() throws -> BoneWorkflowPlan {
        try .init(identity: "demo.live-workflow", revision: 1,
                  steps: [.init(id: .init("main"), kind: DemoLiveWorkflowExecutor.kind, revision: 1)])
    }

    private func recoveryAction(snapshot: BoneWorkflowRunSnapshot, checkpoint: DemoCheckpoint,
                                compatibility: BoneWorkflowCheckpointCompatibility) throws -> DemoLiveWorkflowRecovery {
        guard compatibility == .resumeCompatible, snapshot.run.plan == (try Self.plan()) else { return .inspectOnly }
        // Ask the SDK to validate Step invariants as well as the checkpoint descriptor.
        _ = try BoneWorkflowAgentStepController(restoring: checkpoint.step, persistence: .init { _, _, _ in
            throw DemoWorkflowError.invalidCheckpoint
        })
        switch snapshot.run.state {
        case .completed, .failed, .cancelled: return .terminal
        default: break
        }
        guard snapshot.run.state == .running, checkpoint.phase == .settled,
              checkpoint.step.terminalState != nil, checkpoint.step.pendingAuthorizationTicketID == nil else {
            return .inspectOnly
        }
        return .closeConfirmedStep
    }

    private static func boundedTransport() -> BoneInferenceURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 40
        configuration.timeoutIntervalForResource = maximumWallClockSeconds
        return .init(configuration: configuration, maximumResponseByteCount: maximumOutputBytes)
    }

    private static func safeFailure(_ error: Error) -> DemoLiveWorkflowFailure {
        if let error = error as? BoneAgentError,
           error == .toolOutcomeUnknown || error == .toolRecoveryRequired { return .recoveryRequired }
        if error is CancellationError || Task.isCancelled { return .cancelled }
        if let error = error as? DemoLiveWorkflowFailure { return error }
        if let error = error as? DemoChatConfigurationError { return .configuration(error) }
        return .executionFailed
    }
}

enum DemoLiveWorkflowFailure: Error, Equatable, Sendable {
    case configuration(DemoChatConfigurationError)
    case invalidPrompt, busy, alreadyStarted, cancelled, executionFailed
    case recoveryRequired, unsafeRecovery, noCheckpoint

    var message: String {
        switch self {
        case .configuration(let error): return error.message
        case .invalidPrompt: return "请输入问题，最多 16 KiB。"
        case .busy: return "当前 Run 仍在执行，请等待停止确认。"
        case .alreadyStarted: return "此 Host 已启动过 Run。新建实验后才能再次请求模型。"
        case .cancelled: return "已观察到取消。请核对下面的实际 Run / Step 状态。"
        case .executionFailed: return "执行未完成，请检查模型配置与实际检查点。不会自动重试。"
        case .recoveryRequired: return "提交或执行状态需要核查；未知推理不会重发。"
        case .unsafeRecovery: return "检查点不允许安全收口，保留原状态供检查。"
        case .noCheckpoint: return "尚无可确认的检查点。请新建实验。"
        }
    }
}

enum DemoLiveWorkflowRecovery: Equatable, Sendable {
    case terminal, inspectOnly, closeConfirmedStep

    var message: String {
        switch self {
        case .terminal: return "Run 已终结；检查不会触发模型调用。"
        case .inspectOnly: return "仅检查。已准备派发或未知推理不能续发；检查点计数无法重建缺失的响应。"
        case .closeConfirmedStep: return "SDK 检查点兼容且 Step 终态已确认；可显式收口 Run，模型和工具都不会重跑。"
        }
    }
}

struct DemoLiveWorkflowInspection: Sendable {
    let snapshot: BoneWorkflowRunSnapshot
    let checkpoint: DemoCheckpoint
    let evidence: [DemoLiveWorkflowEvidence]
    let compatibility: BoneWorkflowCheckpointCompatibility
    let recovery: DemoLiveWorkflowRecovery
    let failure: DemoLiveWorkflowFailure?
}

/// Every item comes from an acknowledged store snapshot or an explicit load.
/// It contains no prompt, model response, tool arguments, endpoint or credentials.
struct DemoLiveWorkflowEvidence: Identifiable, Equatable, Sendable {
    let revision: UInt64
    let checkpointRevision: UInt64
    let generation: UInt64
    let runState: BoneWorkflowRunState
    let stepState: BoneWorkflowStepState
    let stepRevision: UInt64
    let phase: DemoPhase
    let inferenceResponses: Int
    let toolResults: Int
    var id: UInt64 { revision }

    var text: String {
        "r\(revision) / cp\(checkpointRevision) · g\(generation) · Run \(runState.rawValue) · Step \(stepState.rawValue) / s\(stepRevision) · \(phase.rawValue) · 响应 \(inferenceResponses) / 工具结果 \(toolResults)"
    }
}

/// Local adapter; the original synthetic DemoStepExecutor.agent defaults are unchanged.
enum DemoLiveWorkflowExecutor {
    static let kind = "live-agent"

    static func make(engine: any BoneInferenceEngine, modelID: String, maximumOutputTokens: Int,
                     tools: [BoneAnyAgentTool], messages: [BoneInferenceMessage], input: DemoInputReference,
                     retainOutput: @escaping @Sendable (BoneAgentRunOutput) async -> Void = { _ in }) throws -> DemoStepExecutor {
        // Validate every candidate before filtering/exposure. No write-capable tool can
        // enter either mode, and a Prompt cannot change this registered policy.
        let all = try BoneAgentToolRegistry(tools: tools)
        let policy = BoneToolImpactPolicy(maximumAllowed: .ordinaryPublicRead)
        for definition in all.definitions {
            let impact = try definition.requiredImpact()
            guard impact.isOrdinaryReadOnly else { throw DemoWorkflowError.invalidScope }
            try policy.authorize(impact)
            _ = try definition.validatedForModelExposure()
        }
        let engine = DemoLiveWorkflowModelEngine(engine: engine, modelID: modelID,
                                                 maximumOutputTokens: maximumOutputTokens)
        let budget = try BoneRunBudget(
            maximumInferenceCalls: DemoLiveWorkflow.maximumInferenceCalls,
            maximumToolCalls: DemoLiveWorkflow.maximumToolCalls,
            maximumInputBytes: DemoLiveWorkflow.maximumInputBytes,
            maximumOutputBytes: DemoLiveWorkflow.maximumOutputBytes,
            maximumTurns: DemoLiveWorkflow.maximumInferenceCalls,
            maximumWallClockSeconds: DemoLiveWorkflow.maximumWallClockSeconds,
            maximumConcurrentToolCalls: 1,
            maximumEstimatedCostMicrounits: Int64.max
        )
        let configuration = try BoneAgentConfiguration(
            maximumSteps: DemoLiveWorkflow.maximumInferenceCalls, runBudget: budget,
            toolImpactPolicy: policy,
            // No monetary estimate is claimed; this only enables the bounded meter.
            inferenceCostEstimator: { _ in 0 },
            logging: .init(logger: DemoLiveWorkflowSilentLogger(), includesSensitivePayloads: false)
        )
        return DemoStepExecutor(kind: kind, revision: 1) { preparation in
            guard preparation.input == input else { throw DemoWorkflowError.inputChanged }
            let registry = try preparation.capabilities.select(tools, mode: preparation.mode, hostPolicy: policy)
            let request = BoneInferenceRequest(modelID: modelID, messages: messages, availableTools: registry.definitions)
            let resolved = try engine.resolvedCapabilities(for: request, invocation: .nonStreaming)
            try BoneInferenceCapabilityValidator.validate(request: request, capabilities: resolved.capabilities,
                                                          invocation: resolved.invocation)
            return DemoPreparedStep(tools: registry.definitions) { context in
                let agent = BoneAgent(inferenceEngine: engine, toolRegistry: registry,
                                      toolContext: BoneAgentEmptyContext(), configuration: configuration,
                                      workflowController: context.controller)
                let result = try await agent.runWorkflowStep(modelID: modelID, messages: messages,
                                                            controller: context.controller)
                await retainOutput(result.output)
                return result.output
            }
        }
    }
}

/// runWorkflowStep currently accepts modelID/messages only. Apply the frozen
/// generation options at this engine boundary, including provider capability checks.
/// There is one underlying infer per SDK invocation, with no retry or fallback.
private struct DemoLiveWorkflowModelEngine: BoneInferenceEngine {
    let engine: any BoneInferenceEngine
    let modelID: String
    let maximumOutputTokens: Int
    var nonImageCapabilities: Set<BoneInferenceCapability> { engine.nonImageCapabilities }
    var imageGenerator: (any BoneInferenceImageGenerating)? { nil }

    func resolvedCapabilities(for request: BoneInferenceRequest,
                              invocation: BoneInferenceInvocationMode) throws -> BoneResolvedInferenceCapabilities {
        try engine.resolvedCapabilities(for: adapted(request), invocation: invocation)
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try Task.checkCancellation()
        let response = try await engine.infer(request: adapted(request))
        try Task.checkCancellation()
        return response
    }

    private func adapted(_ request: BoneInferenceRequest) throws -> BoneInferenceRequest {
        guard request.modelID == modelID else { throw DemoWorkflowError.configurationChanged }
        return .init(modelID: modelID, messages: request.messages, availableTools: request.availableTools,
                     generationOptions: .init(temperature: request.generationOptions.temperature,
                                              maximumOutputTokens: maximumOutputTokens,
                                              reasoning: request.generationOptions.reasoning),
                     responseFormat: request.responseFormat, outputConstraint: request.outputConstraint,
                     providerContinuation: request.providerContinuation, reasoningDisclosure: request.reasoningDisclosure)
    }
}

private actor DemoLiveWorkflowPrivateContent {
    private var prompt: String?
    private var finalText: String?
    func retainPrompt(_ prompt: String) { self.prompt = prompt }
    func retain(_ output: BoneAgentRunOutput) {
        if case .text(let text) = output, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finalText = text
        }
    }
    func response() -> String? { finalText }
}

/// A bounded metadata trace around the SDK's atomic in-memory Run+Checkpoint CAS.
/// Injected stores are used only by tests; no disk or cross-process durability is implied.
private actor DemoLiveWorkflowPersistence: BoneWorkflowPersistence {
    private let storage: any BoneWorkflowPersistence
    private var history: [DemoLiveWorkflowEvidence] = []
    init(storage: any BoneWorkflowPersistence) { self.storage = storage }

    func create(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint) async throws -> BoneWorkflowRunSnapshot {
        let snapshot = try await storage.create(run: run, checkpoint: checkpoint)
        try record(snapshot)
        return snapshot
    }
    func load(runID: BoneRunID) async throws -> BoneWorkflowRunSnapshot {
        let snapshot = try await storage.load(runID: runID)
        try record(snapshot)
        return snapshot
    }
    func commit(run: BoneWorkflowRunRecord, checkpoint: BoneWorkflowCheckpoint,
                expectedRevision: UInt64, leaseGeneration: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let snapshot = try await storage.commit(run: run, checkpoint: checkpoint,
                                                expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
        try record(snapshot)
        return snapshot
    }
    func acquireLease(runID: BoneRunID, expectedRevision: UInt64) async throws -> BoneWorkflowRunSnapshot {
        let snapshot = try await storage.acquireLease(runID: runID, expectedRevision: expectedRevision)
        try record(snapshot)
        return snapshot
    }
    func evidence() -> [DemoLiveWorkflowEvidence] { history }
    private func record(_ snapshot: BoneWorkflowRunSnapshot) throws {
        let checkpoint = try DemoCheckpoint.decode(snapshot)
        guard (history.last?.revision ?? 0) < snapshot.run.revision else { return }
        history.append(.init(revision: snapshot.run.revision, checkpointRevision: snapshot.checkpoint.revision,
                             generation: snapshot.run.leaseGeneration, runState: snapshot.run.state,
                             stepState: checkpoint.step.state, stepRevision: checkpoint.step.persistenceRevision,
                             phase: checkpoint.phase, inferenceResponses: checkpoint.step.inferenceResponseCount,
                             toolResults: checkpoint.step.toolResultCount))
        if history.count > 96 { history.removeFirst(history.count - 96) }
    }
}

/// Demo 中展示长期 Agent Session 状态和本轮输出的只读检查结果。
struct DemoRecoverableAgentSessionInspection: Sendable {
    let session: BoneAgentExecutionSession
    let output: BoneAgentRunOutput?
}

/// Demo 专用的 Agent 装配结果，避免 UI 或测试接触私有 Conversation 状态。
private struct DemoRecoverableAgentAssembly {
    let agent: BoneAgent
    let conversation: BoneAgentConversation
    let binding: BoneAgentExecutionSessionBinding
    let bindingID: String
}

/// Demo 专用的 SHA-256 摘要工具，只对配置和 Tool Catalog 做身份绑定。
private enum DemoRecoverableAgentDigest {
    /// 计算稳定的十六进制 SHA-256 摘要。
    /// - Parameter data: 待摘要的配置字节。
    /// - Returns: 小写十六进制摘要。
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Demo 专用的联合 Session/私有快照内存 Store。
///
/// 它只用于演示 SDK 调用顺序和恢复状态，不代表生产数据库的跨进程耐久性。
private actor DemoRecoverableAgentSessionStore: BoneAgentExecutionSessionStore, BoneWorkflowAgentExecutionSnapshotStore {
    private var sessions: [String: BoneAgentExecutionSession] = [:]
    private var snapshots: [String: BoneWorkflowAgentExecutionSnapshot] = [:]

    /// 创建或等值读取 Demo Session。
    /// - Parameter session: 待创建的 Session。
    /// - Returns: 已确认保存的 Session。
    func open(_ session: BoneAgentExecutionSession) throws -> BoneAgentExecutionSession {
        if let current = sessions[session.sessionID] {
            guard current == session else { throw BoneAgentExecutionSessionError.identityReused }
            return current
        }
        sessions[session.sessionID] = session
        return session
    }

    /// 读取 Demo Session。
    /// - Parameter sessionID: Session 标识。
    /// - Returns: 当前 Session。
    func load(sessionID: String) throws -> BoneAgentExecutionSession {
        guard let session = sessions[sessionID] else { throw BoneAgentExecutionSessionError.missingSession }
        return session
    }

    /// 以 revision 和 lease 做控制面 CAS 提交。
    /// - Parameters: 与 SDK Store 合同相同。
    /// - Returns: Host 确认保存的 Session。
    func commit(
        _ session: BoneAgentExecutionSession,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        try commitChecked(session, snapshot: nil, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }

    /// 在同一 actor 临界区内提交 Session 和私有快照。
    /// - Parameters: 与 SDK 联合提交合同相同。
    /// - Returns: Host 确认保存的 Session。
    func commit(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        try commitChecked(session, snapshot: snapshot, expectedRevision: expectedRevision, leaseGeneration: leaseGeneration)
    }

    /// 获取下一代 lease。
    /// - Parameters:
    ///   - sessionID: 要接管的 Session。
    ///   - expectedRevision: 当前 revision。
    /// - Returns: 已递增 lease generation 的 Session。
    func acquireLease(sessionID: String, expectedRevision: UInt64) throws -> BoneAgentExecutionSession {
        let current = try load(sessionID: sessionID)
        guard current.revision == expectedRevision else { throw BoneAgentExecutionSessionError.revisionConflict }
        let leased = try current.acquiringLease()
        sessions[sessionID] = leased
        return leased
    }

    /// 按完整快照引用读取私有 Conversation 状态。
    /// - Parameter reference: 快照引用。
    /// - Returns: 与引用完全匹配的私有快照。
    func load(reference: BoneWorkflowAgentExecutionSnapshotReference) throws -> BoneWorkflowAgentExecutionSnapshot {
        guard let snapshot = snapshots[reference.referenceID], snapshot.reference == reference else {
            throw BoneWorkflowAgentExecutionSnapshotError.missingSnapshot
        }
        return snapshot
    }

    /// 保存私有快照并校验上一版引用。
    /// - Parameters: 与 SDK 快照 Store 合同相同。
    /// - Returns: 已确认保存的私有快照。
    func commit(
        _ snapshot: BoneWorkflowAgentExecutionSnapshot,
        expectedReference: BoneWorkflowAgentExecutionSnapshotReference?,
        leaseGeneration: UInt64
    ) throws -> BoneWorkflowAgentExecutionSnapshot {
        guard snapshot.reference.leaseGeneration == leaseGeneration,
              expectedReference == nil || snapshots[expectedReference?.referenceID ?? ""]?.reference == expectedReference else {
            throw BoneWorkflowAgentExecutionSnapshotError.revisionConflict
        }
        snapshots[snapshot.reference.referenceID] = snapshot
        return snapshot
    }

    /// 校验并保存 Session 与可选快照。
    /// - Parameters: 与 SDK Session Store 联合提交合同相同。
    /// - Returns: 已确认保存的 Session。
    private func commitChecked(
        _ session: BoneAgentExecutionSession,
        snapshot: BoneWorkflowAgentExecutionSnapshot?,
        expectedRevision: UInt64,
        leaseGeneration: UInt64
    ) throws -> BoneAgentExecutionSession {
        let current = try load(sessionID: session.sessionID)
        guard current.revision == expectedRevision,
              current.leaseGeneration == leaseGeneration,
              session.revision == expectedRevision + 1,
              session.leaseGeneration == leaseGeneration else {
            throw BoneAgentExecutionSessionError.revisionConflict
        }
        if let snapshot {
            guard snapshot.reference == session.snapshotReference else {
                throw BoneAgentExecutionSessionError.identityMismatch
            }
            snapshots[snapshot.reference.referenceID] = snapshot
        }
        sessions[session.sessionID] = session
        return session
    }
}

private struct DemoLiveWorkflowSilentLogger: BoneAgentLogger {
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String,
             context: BoneAgentLogContext?) {}
}
