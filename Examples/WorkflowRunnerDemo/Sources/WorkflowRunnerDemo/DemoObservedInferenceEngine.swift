import BoneAgentKit

/// Keeps the SDK Conversation as the owner of completed state while observing
/// actual Provider deltas. Provider activity/telemetry task locals pass through.
struct DemoObservedInferenceEngine<Engine: BoneInferenceEngine>: BoneInferenceEngine, BoneInferenceBufferedStreaming {
    let engine: Engine
    let observer: DemoLiveChatObserver

    var nonImageCapabilities: Set<BoneInferenceCapability> { engine.nonImageCapabilities }
    var imageGenerator: (any BoneInferenceImageGenerating)? { engine.imageGenerator }

    func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities {
        try engine.resolvedCapabilities(for: request, invocation: invocation)
    }

    func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try Task.checkCancellation()
        await observer(.inferenceStarted)
        try Task.checkCancellation()
        return try await engine.infer(request: request)
    }

    func inferUsingStream(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse {
        try Task.checkCancellation()
        guard let streaming = engine as? any BoneInferenceEventStreaming else {
            throw BoneInferenceError.unsupportedCapability(.streaming)
        }
        let resolved = try engine.resolvedCapabilities(for: request, invocation: .streaming)
        try BoneInferenceCapabilityValidator.validate(
            request: request, capabilities: resolved.capabilities, invocation: resolved.invocation
        )
        await observer(.inferenceStarted)
        try Task.checkCancellation()
        var completed: BoneInferenceResponse?
        for try await event in streaming.inferenceEvents(request: request, options: options) {
            try Task.checkCancellation()
            // Even a second completion or a late usage event makes the stream invalid.
            guard completed == nil else { throw BoneInferenceTransportError.invalidResponse }
            switch event {
            case .textDelta(let text): await observer(.textDelta(text))
            case .completed(let result): completed = result.response
            default: break // Reasoning and tool payloads never become public answer text.
            }
        }
        try Task.checkCancellation()
        guard let completed else { throw BoneInferenceTransportError.invalidResponse }
        return completed
    }
}

// Conditional forwarding preserves optional Engine contracts, especially accurate
// token counting: wrapping a Provider must not manufacture tokenizer support.
extension DemoObservedInferenceEngine: BoneInferenceContextBudgetProviding where Engine: BoneInferenceContextBudgetProviding {
    func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? {
        try engine.contextBudget(for: modelID)
    }
}

extension DemoObservedInferenceEngine: BoneInferenceContextRebinding where Engine: BoneInferenceContextRebinding {
    func rebindContextContinuation(
        _ continuation: BoneInferenceProviderContinuation,
        from original: [BoneInferenceMessage], to compacted: [BoneInferenceMessage]
    ) throws -> BoneInferenceProviderContinuation? {
        try engine.rebindContextContinuation(continuation, from: original, to: compacted)
    }
}

extension DemoObservedInferenceEngine: BoneInferenceImageTokenProviding where Engine: BoneInferenceImageTokenProviding {
    func imageTokens(for image: BoneInferenceImageInput, modelID: String) throws -> Int {
        try engine.imageTokens(for: image, modelID: modelID)
    }

    func imageInputSafetyMarginTokens(for modelID: String) throws -> Int {
        try engine.imageInputSafetyMarginTokens(for: modelID)
    }
}

extension DemoObservedInferenceEngine: BoneInferenceContextTokenCounting where Engine: BoneInferenceContextTokenCounting {
    func countContextTokens(request: BoneInferenceRequest) async throws -> Int {
        try await engine.countContextTokens(request: request)
    }
}

/// Concrete construction preserves provider.kind, endpoint overrides and image
/// configuration without inventing model capability or reasoning profiles.
struct DemoLiveChatEngines: Sendable {
    let raw: any BoneInferenceEngine
    let observed: any BoneInferenceEngine

    private init<Engine: BoneInferenceEngine>(engine: Engine, observer: @escaping DemoLiveChatObserver) {
        raw = engine
        observed = DemoObservedInferenceEngine(engine: engine, observer: observer)
    }

    static func make(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport,
        model: BoneInferenceProviderCatalog.Model?,
        imageInputConfiguration: BoneInferenceImageInputConfiguration?,
        observer: @escaping DemoLiveChatObserver
    ) -> Self {
        let metadata: [String: BoneModelMetadata] = model.flatMap { model in
            model.metadata.map { [model.id: $0] }
        } ?? [:]
        let limits: [String: BoneModelContextLimits] = model.flatMap { model in
            model.tokenLimits.map { [model.id: $0] }
        } ?? [:]
        switch configuration.kind {
        case .google:
            return Self(engine: BoneGeminiInferenceEngine(
                configuration: configuration, transport: transport, modelContextLimits: limits,
                modelMetadata: metadata, imageInputConfiguration: imageInputConfiguration
            ), observer: observer)
        case .anthropic, .miniMax:
            return Self(engine: BoneAnthropicInferenceEngine(
                configuration: configuration, transport: transport, modelContextLimits: limits,
                modelMetadata: metadata, imageInputConfiguration: imageInputConfiguration
            ), observer: observer)
        case .openAI, .zhipu, .siliconFlow, .newAPI, .custom, .agnes:
            return Self(engine: BoneOpenAIInferenceEngine(
                configuration: configuration, transport: transport, modelContextLimits: limits,
                modelMetadata: metadata, imageInputConfiguration: imageInputConfiguration
            ), observer: observer)
        }
    }
}
