import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public final class BoneLlamaInferenceEngine: BoneInferenceEngine, @unchecked Sendable {
    public let nonImageCapabilities: Set<BoneInferenceCapability>
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let modelID: String
    private let session: Session

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
            promptEncoder: promptEncoder,
            toolCalling: toolCalling,
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

private actor Session {
    let modelID: String
    let modelURL: URL
    let plan: BoneLocalRuntimePlan
    let promptEncoder: any BoneLlamaPromptEncoding
    let toolCalling: (any BoneLlamaToolCalling)?
    let runtime: any BoneLlamaRuntime
    var isLoaded = false

    private var revision: UInt64 = 0
    private var state: BoneLlamaModelState
    private var subscribers: [UUID: AsyncStream<BoneLlamaModelState>.Continuation] = [:]

    init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        promptEncoder: any BoneLlamaPromptEncoding,
        toolCalling: (any BoneLlamaToolCalling)?,
        runtime: any BoneLlamaRuntime
    ) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.plan = plan
        self.promptEncoder = promptEncoder
        self.toolCalling = toolCalling
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
        if let toolCalling { return try toolCalling.encode(request: request) }
        return try promptEncoder.encode(request: request)
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
        let prompt: String
        if let toolCalling {
            prompt = try toolCalling.encode(request: request)
        } else {
            prompt = try promptEncoder.encode(request: request)
        }
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
            publish(.generating, configuration: configuration)
            let result = try await runtime.generate(prompt: prompt, options: options)
            let response: BoneInferenceResponse
            if let toolCalling {
                response = try toolCalling.decode(
                    output: result.text,
                    availableTools: request.availableTools
                )
            } else {
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
                response = .finish(.init(text: text))
            }
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
