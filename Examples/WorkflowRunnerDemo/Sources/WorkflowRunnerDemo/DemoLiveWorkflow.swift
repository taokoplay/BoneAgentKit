import Foundation
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
    private var isDriving = false
    private var failure: DemoLiveWorkflowFailure?

    private init(settings: DemoLiveChatSettings, engine: any BoneInferenceEngine,
                 persistence: any BoneWorkflowPersistence) {
        self.settings = settings
        self.engine = engine
        self.persistence = DemoLiveWorkflowPersistence(storage: persistence)
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

private struct DemoLiveWorkflowSilentLogger: BoneAgentLogger {
    func log(_ level: BoneAgentLogLevel, message: @autoclosure @Sendable () -> String,
             context: BoneAgentLogContext?) {}
}
