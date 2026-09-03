import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public final class BoneLlamaInferenceEngine: BoneInferenceEngine, @unchecked Sendable {
    public let nonImageCapabilities: Set<BoneInferenceCapability>
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let modelID: String
    private let session: Session

    /// alpha.6 兼容入口；Prompt Encoder 或 Tool Calling Adapter 已包含完整模板渲染。
    public init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        promptEncoder: any BoneLlamaPromptEncoding = BoneLlamaChatMLPromptEncoder(),
        toolCalling: (any BoneLlamaToolCalling)? = nil,
        verifiedCapabilityProfile: BoneModelCapabilityProfile? = nil,
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        self.modelID = modelID
        let implemented: Set<BoneInferenceCapability> = toolCalling == nil
            ? [.text]
            : [.text, .toolCalling]
        nonImageCapabilities = verifiedCapabilityProfile?
            .resolved(engineCapabilities: implemented) ?? implemented
        session = Session(
            modelID: modelID,
            modelURL: modelURL,
            plan: plan,
            pipeline: .legacy(promptEncoder: promptEncoder, toolCalling: toolCalling),
            runtime: runtimeFactory()
        )
    }

    /// 模板唯一渲染入口；Tool Envelope 只编码 Tool 语义，不包含模型模板 Token。
    public init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        conversationRenderer: any BoneLlamaConversationRendering,
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)? = nil,
        verifiedCapabilityProfile: BoneModelCapabilityProfile? = nil,
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        self.modelID = modelID
        let implemented: Set<BoneInferenceCapability> = toolEnvelope == nil
            ? [.text]
            : [.text, .toolCalling]
        nonImageCapabilities = verifiedCapabilityProfile?
            .resolved(engineCapabilities: implemented) ?? implemented
        session = Session(
            modelID: modelID,
            modelURL: modelURL,
            plan: plan,
            pipeline: .canonical(renderer: conversationRenderer, toolEnvelope: toolEnvelope),
            runtime: runtimeFactory()
        )
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocation
    ) throws -> BoneResolvedInferenceCapabilities {
        guard request.modelID == modelID else { throw BoneLlamaAdapterError.modelMismatch }
        _ = try session.validateSynchronously(request)
        return .init(modelID: modelID, invocation: invocation, capabilities: nonImageCapabilities)
    }

    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        guard request.modelID == modelID else { throw BoneLlamaAdapterError.modelMismatch }
        return try await session.infer(request)
    }

    public func currentModelState() async -> BoneLlamaModelState {
        await session.currentState()
    }

    public func modelStateUpdates() async -> AsyncStream<BoneLlamaModelState> {
        await session.stateUpdates()
    }

    public func cancel() async { await session.cancel() }
    public func unload() async { await session.unload() }
}

private enum BoneLlamaInferencePipeline: Sendable {
    case legacy(
        promptEncoder: any BoneLlamaPromptEncoding,
        toolCalling: (any BoneLlamaToolCalling)?
    )
    case canonical(
        renderer: any BoneLlamaConversationRendering,
        toolEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    )
}

private actor Session {
    let modelID: String
    let modelURL: URL
    let plan: BoneLocalRuntimePlan
    let pipeline: BoneLlamaInferencePipeline
    let runtime: any BoneLlamaRuntime
    var isLoaded = false

    private var revision: UInt64 = 0
    private var state: BoneLlamaModelState
    private var subscribers: [UUID: AsyncStream<BoneLlamaModelState>.Continuation] = [:]

    init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        pipeline: BoneLlamaInferencePipeline,
        runtime: any BoneLlamaRuntime
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.plan = plan
        self.pipeline = pipeline
        self.runtime = runtime
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
        switch pipeline {
        case let .legacy(promptEncoder, toolCalling):
            if let toolCalling { return try toolCalling.encode(request: request) }
            return try promptEncoder.encode(request: request)
        case let .canonical(_, toolEnvelope):
            _ = try BoneLlamaConversationBuilder.build(
                request: request,
                toolEnvelope: toolEnvelope
            )
            return "canonical"
        }
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
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: request.generationOptions,
            plan: plan
        )
        let configuration = BoneLlamaRuntimeConfiguration(plan: plan)
        do {
            if !isLoaded {
                publish(.loading, configuration: configuration)
                try await runtime.load(modelURL: modelURL, configuration: configuration)
                isLoaded = true
                publish(.loaded, configuration: configuration)
            }
            let prepared = try await prepare(request)
            let prompt = prepared.prompt
            let tokenization = try await runtime.tokenize(prompt: prompt)
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
            if prepared.control.requiresControlledRuntime {
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
            guard result.termination != .maximumTokens else {
                throw BoneLlamaAdapterError.outputTruncated
            }
            let response = try decode(
                result.text,
                request: request,
                canonicalEnvelope: prepared.envelope
            )
            publish(.loaded, configuration: configuration)
            return response
        } catch let error as BoneLlamaAdapterError {
            publish(.failed, configuration: configuration)
            throw error
        } catch let error as BoneLlamaRuntimeError {
            publish(.failed, configuration: configuration, failure: error)
            throw BoneLlamaAdapterError.runtime(error)
        } catch {
            publish(.failed, configuration: configuration)
            throw error
        }
    }

    private func prepare(
        _ request: BoneInferenceRequest
    ) async throws -> (
        prompt: String,
        control: BoneLlamaGenerationControl,
        envelope: (any BoneLlamaToolEnvelopeCoding)?
    ) {
        switch pipeline {
        case let .legacy(promptEncoder, toolCalling):
            let prompt = try toolCalling?.encode(request: request)
                ?? promptEncoder.encode(request: request)
            return (prompt, try .init(), nil)
        case let .canonical(renderer, toolEnvelope):
            let conversation = try BoneLlamaConversationBuilder.build(
                request: request,
                toolEnvelope: toolEnvelope
            )
            let rendered = try await renderer.render(
                conversation: conversation,
                using: runtime
            )
            let envelopeConstraint = try toolEnvelope?.generationConstraint(
                tools: request.availableTools
            )
            guard rendered.generationControl.constraint == nil || envelopeConstraint == nil else {
                throw BoneLlamaAdapterError.invalidGenerationControl
            }
            let control = try BoneLlamaGenerationControl(
                stopTokenIDs: rendered.generationControl.stopTokenIDs,
                stopStrings: rendered.generationControl.stopStrings,
                constraint: rendered.generationControl.constraint ?? envelopeConstraint
            )
            return (rendered.prompt, control, toolEnvelope)
        }
    }

    private func decode(
        _ output: String,
        request: BoneInferenceRequest,
        canonicalEnvelope: (any BoneLlamaToolEnvelopeCoding)?
    ) throws -> BoneInferenceResponse {
        switch pipeline {
        case let .legacy(_, toolCalling):
            if let toolCalling {
                return try toolCalling.decode(output: output, availableTools: request.availableTools)
            }
        case .canonical:
            if let canonicalEnvelope {
                return try canonicalEnvelope.decode(output: output, availableTools: request.availableTools)
            }
        }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
        return .finish(.init(text: text))
    }

    func cancel() async {
        let configuration = isLoaded ? BoneLlamaRuntimeConfiguration(plan: plan) : nil
        publish(.cancelling, configuration: configuration)
        await runtime.cancel()
        publish(isLoaded ? .loaded : .notLoaded, configuration: configuration)
    }

    func unload() async {
        let configuration = isLoaded ? BoneLlamaRuntimeConfiguration(plan: plan) : nil
        publish(.unloading, configuration: configuration)
        await runtime.unload()
        isLoaded = false
        publish(.notLoaded)
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
