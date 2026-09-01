import BoneAgentKit
import BoneAgentLocalRuntime
import Foundation

public final class BoneLlamaInferenceEngine: BoneInferenceEngine, @unchecked Sendable {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [.text]
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let modelID: String
    private let session: Session

    public init(
        modelID: String,
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        promptEncoder: any BoneLlamaPromptEncoding = BoneLlamaChatMLPromptEncoder(),
        runtimeFactory: @escaping BoneLlamaRuntimeFactory
    ) {
        self.modelID = modelID
        session = Session(
            modelURL: modelURL,
            plan: plan,
            promptEncoder: promptEncoder,
            runtime: runtimeFactory()
        )
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocation
    ) throws -> BoneResolvedInferenceCapabilities {
        guard request.modelID == modelID else { throw BoneLlamaAdapterError.modelMismatch }
        _ = try session.validateSynchronously(request)
        return .init(modelID: modelID, invocation: invocation, capabilities: [.text])
    }

    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        guard request.modelID == modelID else { throw BoneLlamaAdapterError.modelMismatch }
        return try await session.infer(request)
    }

    public func cancel() async { await session.cancel() }
    public func unload() async { await session.unload() }
}

private actor Session {
    let modelURL: URL
    let plan: BoneLocalRuntimePlan
    let promptEncoder: any BoneLlamaPromptEncoding
    let runtime: any BoneLlamaRuntime
    var isLoaded = false

    init(
        modelURL: URL,
        plan: BoneLocalRuntimePlan,
        promptEncoder: any BoneLlamaPromptEncoding,
        runtime: any BoneLlamaRuntime
    ) {
        self.modelURL = modelURL
        self.plan = plan
        self.promptEncoder = promptEncoder
        self.runtime = runtime
    }

    nonisolated func validateSynchronously(_ request: BoneInferenceRequest) throws -> String {
        try promptEncoder.encode(request: request)
    }

    func infer(_ request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        let prompt = try promptEncoder.encode(request: request)
        let options = try BoneLlamaGenerationOptions(
            inferenceOptions: request.generationOptions,
            plan: plan
        )
        do {
            if !isLoaded {
                try await runtime.load(
                    modelURL: modelURL,
                    configuration: .init(plan: plan)
                )
                isLoaded = true
            }
            let result = try await runtime.generate(prompt: prompt, options: options)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
            return .finish(.init(text: text))
        } catch let error as BoneLlamaAdapterError {
            throw error
        } catch let error as BoneLlamaRuntimeError {
            throw BoneLlamaAdapterError.runtime(error)
        }
    }

    func cancel() async { await runtime.cancel() }

    func unload() async {
        await runtime.unload()
        isLoaded = false
    }
}
