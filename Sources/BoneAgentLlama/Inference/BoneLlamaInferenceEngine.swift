import BoneAgentKit
import BoneAgentLocalModels
import Foundation

public final class BoneLlamaInferenceEngine: BoneInferenceEngine, @unchecked Sendable {
    public let nonImageCapabilities: Set<BoneInferenceCapability>
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let modelID: String
    private let session: Session

    /// 模板唯一渲染入口；Tool Envelope 只编码 Tool 语义，不包含模型模板 Token。
    public init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        conversationRenderer: any BoneLlamaConversationRendering = BoneLlamaChatMLConversationRenderer(),
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)? = nil,
        verifiedCapabilityProfile: BoneModelCapabilityProfile? = nil,
        currentVerificationIdentity: BoneLocalExecutionVerificationIdentity? = nil,
        constraintCompiler: (any BoneLlamaConstraintCompiling)? = nil,
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        self.modelID = modelID
        var implemented: Set<BoneInferenceCapability> = toolEnvelope == nil
            ? [.text]
            : [.text, .toolCalling]
        if constraintCompiler != nil { implemented.insert(.constrainedOutput) }
        let runtime = runtimeFactory()
        nonImageCapabilities = Self.resolvedCapabilities(
            implemented: implemented,
            profile: verifiedCapabilityProfile,
            currentIdentity: currentVerificationIdentity,
            runtimeVersion: runtime.runtimeVersion,
            toolEnvelopeIdentity: toolEnvelope?.identity,
            constraintCompilerIdentity: constraintCompiler?.identity
        )
        session = Session(
            modelID: modelID,
            modelURL: modelURL,
            plan: plan,
            renderer: conversationRenderer,
            toolEnvelope: toolEnvelope,
            constraintCompiler: constraintCompiler,
            runtime: runtime,
            expectedIdentity: currentVerificationIdentity
        )
    }

    private static func resolvedCapabilities(
        implemented: Set<BoneInferenceCapability>,
        profile: BoneModelCapabilityProfile?,
        currentIdentity: BoneLocalExecutionVerificationIdentity?,
        runtimeVersion: Int,
        toolEnvelopeIdentity: BoneLlamaToolEnvelopeIdentity?,
        constraintCompilerIdentity: BoneLlamaConstraintCompilerIdentity?
    ) -> Set<BoneInferenceCapability> {
        guard let profile else {
            return implemented.subtracting([.constrainedOutput])
        }
        var resolved = profile.resolved(engineCapabilities: implemented)
        let advanced: Set<BoneInferenceCapability> = [.toolCalling, .constrainedOutput]
        if !resolved.isDisjoint(with: advanced) {
            guard profile.source == .runtimeSmoke,
                  let verifiedIdentity = profile.verificationIdentity,
                  let currentIdentity,
                  verifiedIdentity.matches(currentIdentity),
                  currentIdentity.runtimeVersion == runtimeVersion else {
                resolved.subtract(advanced)
                return resolved
            }
            if resolved.contains(.toolCalling),
               !Self.matches(toolEnvelopeIdentity, currentIdentity: currentIdentity) {
                resolved.remove(.toolCalling)
            }
            if resolved.contains(.constrainedOutput),
               (!verifiedIdentity.hasConstraintRuntimeIdentity
                   || !currentIdentity.hasConstraintRuntimeIdentity
                   || !Self.matches(constraintCompilerIdentity, currentIdentity: currentIdentity)) {
                resolved.remove(.constrainedOutput)
            }
        }
        return resolved
    }

    private static func matches(
        _ actual: BoneLlamaToolEnvelopeIdentity?,
        currentIdentity: BoneLocalExecutionVerificationIdentity
    ) -> Bool {
        actual?.id == currentIdentity.toolEnvelopeID
            && actual?.version == currentIdentity.toolEnvelopeVersion
    }

    private static func matches(
        _ actual: BoneLlamaConstraintCompilerIdentity?,
        currentIdentity: BoneLocalExecutionVerificationIdentity
    ) -> Bool {
        actual?.id == currentIdentity.constraintCompilerID
            && actual?.version == currentIdentity.constraintCompilerVersion
            && actual?.dialect == currentIdentity.constraintDialect
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities {
        guard request.modelID == modelID else { throw BoneLlamaAdapterError.modelMismatch }
        _ = try session.validateSynchronously(request)
        return .init(modelID: modelID, invocation: invocation, capabilities: nonImageCapabilities)
    }

    /// One request owns the entire load/render/tokenize/generate lifecycle. Concurrent
    /// requests fail with BoneLlamaAdapterError.busy rather than queueing.
    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let resolved = try resolvedCapabilities(for: request, invocation: .nonStreaming)
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: resolved.capabilities,
            invocation: resolved.invocation
        )
        return try await session.infer(request)
    }

    public func currentModelState() async -> BoneLlamaModelState {
        await session.currentState()
    }

    public func modelStateUpdates() async -> AsyncStream<BoneLlamaModelState> {
        await session.stateUpdates()
    }

    /// Requests cooperative cancellation. Native work may continue until its current call returns.
    public func cancel() async { await session.cancel() }
    /// Cancels and drains in-flight work before releasing the runtime; may wait indefinitely
    /// for a runtime that does not cooperate. New inference is rejected while draining.
    public func unload() async { await session.unload() }
}

private actor Session {
    let modelID: String
    let modelURL: URL
    let plan: BoneLocalRuntimePlan
    let renderer: any BoneLlamaConversationRendering
    let toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    let constraintCompiler: (any BoneLlamaConstraintCompiling)?
    let runtime: any BoneLlamaRuntime
    let expectedIdentity: BoneLocalExecutionVerificationIdentity?
    private enum ResourceState { case notLoaded, loading, loaded }
    private var resourceState = ResourceState.notLoaded
    private var operationID: UUID?
    private var operationCancelled = false
    private var cleaningResource = false
    private var cancellationTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    private var revision: UInt64 = 0
    private var state: BoneLlamaModelState
    private var subscribers: [UUID: AsyncStream<BoneLlamaModelState>.Continuation] = [:]

    init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        renderer: any BoneLlamaConversationRendering,
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?,
        constraintCompiler: (any BoneLlamaConstraintCompiling)?,
        runtime: any BoneLlamaRuntime,
        expectedIdentity: BoneLocalExecutionVerificationIdentity?
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.plan = plan
        self.renderer = renderer
        self.toolEnvelope = toolEnvelope
        self.constraintCompiler = constraintCompiler
        self.runtime = runtime
        self.expectedIdentity = expectedIdentity
        state = .init(
            modelID: modelID,
            runtimeState: .init(
                phase: .notLoaded,
                revision: 0,
                runtimeVersion: runtime.runtimeVersion
            )
        )
    }

    deinit {
        for continuation in subscribers.values { continuation.finish() }
    }

    nonisolated func validateSynchronously(_ request: BoneInferenceRequest) throws -> String {
        _ = try BoneLlamaConversationBuilder.build(
            request: request,
            toolEnvelope: toolEnvelope
        )
        return "canonical"
    }

    func currentState() -> BoneLlamaModelState { state }

    func stateUpdates() -> AsyncStream<BoneLlamaModelState> {
        let id = UUID()
        let current = state
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func infer(_ request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        guard operationID == nil, unloadTask == nil else {
            throw BoneLlamaAdapterError.busy
        }
        guard !Task.isCancelled else { throw BoneLlamaAdapterError.runtime(.cancelled) }
        let id = UUID()
        operationID = id
        operationCancelled = false
        return try await withTaskCancellationHandler {
            do {
                let response = try await runInference(request, id: id)
                try checkOperation(id)
                await finishOperation(id)
                return response
            } catch {
                // A cancelled operation owns its slot until all runtime/control calls drain.
                let cancelled = operationCancelled || Task.isCancelled
                if cancelled { requestCancellation(id) }
                await finishOperation(id)
                if cancelled { throw BoneLlamaAdapterError.runtime(.cancelled) }
                throw error
            }
        } onCancel: {
            Task { await self.requestCancellation(id) }
        }
    }

    private func checkOperation(_ id: UUID) throws {
        guard operationID == id, !operationCancelled, !Task.isCancelled else {
            throw BoneLlamaAdapterError.runtime(.cancelled)
        }
    }

    private func runInference(_ request: BoneInferenceRequest, id: UUID) async throws -> BoneInferenceResponse {
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: request.generationOptions,
            plan: plan
        )
        let configuration = BoneLlamaRuntimeConfiguration(plan: plan)
        do {
            try checkOperation(id)
            if request.outputConstraint != nil || !request.availableTools.isEmpty {
                try await validateRuntimeIdentity(id: id)
                try checkOperation(id)
            }
            if resourceState != .loaded {
                resourceState = .loading
                publish(.loading, configuration: configuration)
                try await runtime.load(modelURL: modelURL, configuration: configuration)
                resourceState = .loaded
                try checkOperation(id)
                publish(.loaded, configuration: configuration)
            }
            let prepared = try await prepare(request)
            try checkOperation(id)
            let prompt = prepared.prompt
            let tokenization = try await runtime.tokenize(prompt: prompt)
            try checkOperation(id)
            let executionPlan = try BoneLlamaPromptExecutionPlanner.plan(
                tokenization: tokenization,
                configuration: configuration,
                requestedMaximumOutputTokens: options.maximumOutputTokens
            )
            let effectiveOptions = try BoneLlamaGenerationOptions(
                maximumOutputTokens: executionPlan.maximumOutputTokens,
                temperature: options.temperature
            )
            publish(.generating, configuration: configuration)
            let result: BoneLlamaGenerationResult
            if prepared.control.constraint != nil {
                guard let compiled = runtime as? any BoneLlamaConstraintGenerationRuntime else {
                    throw BoneLlamaAdapterError.unsupportedGenerationControl
                }
                result = try await compiled.generate(
                    prompt: prompt,
                    executionPlan: executionPlan,
                    options: effectiveOptions,
                    control: try BoneLlamaResolvedGenerationControl(
                        control: prepared.control,
                        compiler: prepared.constraintCompiler
                    )
                )
            } else if prepared.control.requiresControlledRuntime {
                guard let controlled = runtime as? any BoneLlamaControlledGenerationRuntime else {
                    throw BoneLlamaAdapterError.unsupportedGenerationControl
                }
                result = try await controlled.generate(
                    prompt: prompt,
                    executionPlan: executionPlan,
                    options: effectiveOptions,
                    control: prepared.control
                )
            } else {
                result = try await runtime.generate(
                    prompt: prompt,
                    executionPlan: executionPlan,
                    options: effectiveOptions
                )
            }
            try checkOperation(id)
            try BoneLlamaTerminationValidator.validate(
                result.termination,
                control: prepared.control,
                requiresCompleteOutput: prepared.envelope != nil || prepared.control.constraint != nil
            )
            try validateConstrainedOutput(result.text, constraint: prepared.control.constraint)
            guard !Self.containsReasoningMarker(result.text) else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            let response = try decode(
                result.text,
                request: request,
                canonicalEnvelope: prepared.envelope
            )
            try checkOperation(id)
            publish(.loaded, configuration: configuration)
            return response
        } catch let error as BoneLlamaAdapterError {
            try checkOperation(id)
            publish(.failed, configuration: configuration)
            throw error
        } catch let error as BoneLlamaRuntimeError {
            try checkOperation(id)
            publish(.failed, configuration: configuration, failure: error)
            throw BoneLlamaAdapterError.runtime(error)
        } catch {
            try checkOperation(id)
            publish(.failed, configuration: configuration)
            throw error
        }
    }

    private func validateRuntimeIdentity(id: UUID) async throws {
        try checkOperation(id)
        guard let expectedIdentity else { return }
        guard let identifying = runtime as? any BoneLlamaRuntimeVerificationIdentifying else {
            throw BoneLlamaAdapterError.invalidConfiguration
        }
        let components = try await identifying.verificationComponents()
        try checkOperation(id)
        guard components.tokenizerID == expectedIdentity.tokenizerID,
              components.tokenizerVersion == expectedIdentity.tokenizerVersion,
              components.grammarParserID == expectedIdentity.grammarParserID,
              components.grammarParserVersion == expectedIdentity.grammarParserVersion,
              components.grammarSamplerID == expectedIdentity.grammarSamplerID,
              components.grammarSamplerVersion == expectedIdentity.grammarSamplerVersion,
              components.stopMatcherID == expectedIdentity.stopMatcherID,
              components.stopMatcherVersion == expectedIdentity.stopMatcherVersion else {
            throw BoneLlamaAdapterError.invalidConfiguration
        }
    }

    private func prepare(
        _ request: BoneInferenceRequest
    ) async throws -> (
        prompt: String,
        control: BoneLlamaGenerationControl,
        envelope: (any BoneLlamaToolEnvelopeCoding)?,
        constraintCompiler: (any BoneLlamaConstraintCompiling)?
    ) {
        let conversation = try BoneLlamaConversationBuilder.build(
            request: request,
            toolEnvelope: toolEnvelope
        )
        let rendered = try await renderer.render(
            conversation: conversation,
            using: runtime
        )
        if request.outputConstraint != nil || !request.availableTools.isEmpty,
           let expectedIdentity {
            guard rendered.templateIdentity.templateDigest == expectedIdentity.templateDigest,
                  rendered.templateIdentity.rendererID == expectedIdentity.rendererID,
                  rendered.templateIdentity.rendererVersion == expectedIdentity.rendererVersion,
                  rendered.templateIdentity.reasoningMode.rawValue == expectedIdentity.reasoningMode,
                  rendered.templateIdentity.addGenerationPrompt == expectedIdentity.addGenerationPrompt else {
                throw BoneLlamaAdapterError.invalidConfiguration
            }
        }
        let envelopeConstraint = try toolEnvelope?.generationConstraint(
            tools: request.availableTools
        )
        let requestConstraint = try request.outputConstraint.map(BoneLlamaOutputConstraintAdapter.map)
        let constraintCount = [
            rendered.generationControl.constraint,
            envelopeConstraint,
            requestConstraint,
        ].compactMap { $0 }.count
        guard constraintCount <= 1 else {
            throw BoneLlamaAdapterError.invalidGenerationControl
        }
        let control = try BoneLlamaGenerationControl(
            stopTokenIDs: rendered.generationControl.stopTokenIDs,
            stopStrings: rendered.generationControl.stopStrings,
            constraint: rendered.generationControl.constraint ?? envelopeConstraint ?? requestConstraint
        )
        if requestConstraint != nil, constraintCompiler == nil {
            throw BoneLlamaAdapterError.unsupportedGenerationControl
        }
        return (rendered.prompt, control, toolEnvelope, constraintCompiler)
    }

    private func validateConstrainedOutput(
        _ output: String,
        constraint: BoneLlamaGenerationConstraint?
    ) throws {
        guard let constraint else { return }
        do {
            switch constraint {
            case let .enumChoice(choices):
                guard choices.contains(output) else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
            case let .jsonSchema(schema):
                try BoneToolSchemaValidator.validate(
                    arguments: Data(output.utf8),
                    against: schema
                )
            }
        } catch let error as BoneLlamaAdapterError {
            throw error
        } catch {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }

    private static func containsReasoningMarker(_ output: String) -> Bool {
        let lowercased = output.lowercased()
        return lowercased.contains("<think>") || lowercased.contains("</think>")
    }

    private func decode(
        _ output: String,
        request: BoneInferenceRequest,
        canonicalEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    ) throws -> BoneInferenceResponse {
        if let outputConstraint = request.outputConstraint {
            return try BoneLlamaOutputConstraintAdapter.decode(
                output,
                constraint: outputConstraint
            )
        }
        if let canonicalEnvelope {
            return try canonicalEnvelope.decode(output: output, availableTools: request.availableTools)
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
        return .finish(.init(text: text))
    }

    /// Identity-scoped: a delayed task cancellation cannot cancel a subsequent inference.
    private func requestCancellation(_ id: UUID) {
        guard operationID == id, !operationCancelled else { return }
        operationCancelled = true
        if unloadTask == nil {
            publish(.cancelling, configuration: BoneLlamaRuntimeConfiguration(plan: plan))
        }
        guard !cleaningResource else { return }
        let runtime = self.runtime
        cancellationTask = Task { await runtime.cancel() }
    }

    private func finishOperation(_ id: UUID) async {
        guard operationID == id else { return }
        // Keep admission closed until even a late cancel() callback has returned.
        if let cancellationTask { await cancellationTask.value }
        if operationCancelled || resourceState == .loading {
            // A failed load may have partially allocated resources. Retain the operation
            // slot until cleanup returns, without unloading ordinary output failures.
            cleaningResource = true
            await runtime.unload()
            cleaningResource = false
            resourceState = .notLoaded
            // Preserve the typed load failure snapshot unless cancellation took over.
            if operationCancelled && unloadTask == nil { publish(.notLoaded) }
        }
        cancellationTask = nil
        operationID = nil
        operationCancelled = false
        let waiters = drainWaiters
        drainWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func cancel() async {
        guard let id = operationID else { return }
        requestCancellation(id)
        if let cancellationTask { await cancellationTask.value }
    }

    func unload() async {
        if let unloadTask {
            await unloadTask.value
            return
        }
        // Install the shared task before yielding; all unload callers join this drain.
        let task = Task { await self.performUnload() }
        unloadTask = task
        publish(.unloading, configuration: BoneLlamaRuntimeConfiguration(plan: plan))
        if let id = operationID { requestCancellation(id) }
        await task.value
    }

    private func performUnload() async {
        if operationID != nil {
            await withCheckedContinuation { drainWaiters.append($0) }
        }
        if resourceState != .notLoaded {
            await runtime.unload()
            resourceState = .notLoaded
        }
        publish(.notLoaded)
        unloadTask = nil
    }

    private func publish(
        _ phase: BoneLlamaRuntimePhase,
        configuration: BoneLlamaRuntimeConfiguration? = nil,
        failure: BoneLlamaRuntimeError? = nil
    ) {
        revision &+= 1
        state = .init(
            modelID: modelID,
            runtimeState: .init(
                phase: phase,
                revision: revision,
                runtimeVersion: runtime.runtimeVersion,
                configuration: configuration,
                failure: failure
            )
        )
        for continuation in subscribers.values { continuation.yield(state) }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}
