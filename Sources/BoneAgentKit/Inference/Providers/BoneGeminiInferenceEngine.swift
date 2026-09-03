import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini GenerateContent 协议的通用推理实现。
public struct BoneGeminiInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming,
    BoneInferenceDetailedResultProviding, BoneInferenceDetailedStreaming, BoneInferenceEventStreaming {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [
        .text, .structuredOutput, .constrainedOutput, .toolCalling, .streaming,
    ]
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport
    private let modelCapabilityProfiles: [String: BoneModelCapabilityProfile]

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport,
        modelCapabilityProfiles: [String: BoneModelCapabilityProfile] = [:]
    ) {
        self.configuration = configuration
        self.transport = transport
        self.modelCapabilityProfiles = modelCapabilityProfiles
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocation
    ) throws -> BoneResolvedInferenceCapabilities {
        var resolved = modelCapabilityProfiles[request.modelID]?
            .resolved(engineCapabilities: capabilities) ?? capabilities
        resolved.remove(.constrainedOutput)
        if let constraint = request.outputConstraint,
           configuration.kind == .google,
           BoneGeminiOutputConstraintAdapter().supports(constraint),
           let identity = try? constraintVerificationIdentity(modelID: request.modelID, invocation: invocation),
           BoneProviderVerificationIdentitySupport.isVerified(
               profile: modelCapabilityProfiles[request.modelID],
               currentIdentity: identity
           ) {
            resolved.insert(.constrainedOutput)
        }
        return .init(modelID: request.modelID, invocation: invocation, capabilities: resolved)
    }

    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try await inferDetailed(request: request).response
    }

    public func inferDetailed(
        request: BoneInferenceRequest
    ) async throws -> BoneInferenceDetailedResult {
        let resolved = try resolvedCapabilities(for: request, invocation: .nonStreaming)
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: resolved.capabilities,
            invocation: resolved.invocation
        )
        let urlRequest = try makeRequest(request, streaming: false)
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        let finalResponse: BoneInferenceResponse
        if let constraint = request.outputConstraint {
            let text = try BoneGeminiResponseAggregator.text(from: json)
            finalResponse = try BoneGeminiOutputConstraintAdapter().response(
                from: Data(text.utf8),
                constraint: constraint
            )
        } else if request.responseFormat.isStructured {
            guard request.availableTools.isEmpty else { throw BoneInferenceError.invalidStructuredOutputContract }
            finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                from: BoneGeminiResponseAggregator.text(from: json),
                schema: request.responseFormat.schema?.root
            )
        } else if request.availableTools.isEmpty {
            finalResponse = .finish(.init(text: try BoneGeminiResponseAggregator.text(from: json)))
        } else {
            finalResponse = try BoneGeminiToolWire.parseResponse(json, definitions: request.availableTools)
        }
        return .init(
            response: finalResponse,
            reasoning: BoneInferenceReasoningSupport.gemini(
                json: json,
                disclosure: request.reasoningDisclosure
            )
        )
    }

    public func streamInference(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse {
        try await streamInferenceDetailed(request: request, options: options).response
    }

    public func inferenceEvents(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) -> BoneInferenceNormalizedEventStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let resolved = try resolvedCapabilities(for: request, invocation: .streaming)
                    try BoneInferenceCapabilityValidator.validate(
                        request: request,
                        capabilities: resolved.capabilities,
                        invocation: resolved.invocation
                    )
                    let urlRequest = try makeRequest(request, streaming: true)
                    var events: [BoneInferenceEventStreamEvent] = []
                    var mapper = BoneGeminiNormalizedEventMapper(
                        disclosure: request.reasoningDisclosure,
                        definitions: request.availableTools
                    )
                    for try await event in transport.eventStream(urlRequest, options: options) {
                        events.append(event)
                        for mapped in try mapper.consume(event) { continuation.yield(mapped) }
                    }
                    let aggregated = try BoneGeminiToolStreamAggregator.aggregate(events: events, definitions: request.availableTools)
                    let response: BoneInferenceResponse
                    if let constraint = request.outputConstraint {
                        guard case let .assistantTurn(turn, reason, _, refusal, _) = aggregated,
                              reason == .stop, refusal == nil, let text = turn.text else {
                            throw BoneInferenceTransportError.invalidResponse
                        }
                        response = try BoneGeminiOutputConstraintAdapter().response(
                            from: Data(text.utf8),
                            constraint: constraint
                        )
                    } else if request.responseFormat.isStructured {
                        guard case let .assistantTurn(turn, reason, _, refusal, _) = aggregated,
                              reason == .stop, refusal == nil, let text = turn.text else {
                            throw BoneInferenceTransportError.invalidResponse
                        }
                        response = try BoneStructuredOutputSupport.structuredResponse(
                            from: text,
                            schema: request.responseFormat.schema?.root
                        )
                    } else {
                        response = aggregated
                    }
                    let result = BoneInferenceDetailedResult(
                        response: response,
                        reasoning: BoneInferenceReasoningSupport.gemini(events: events, disclosure: request.reasoningDisclosure)
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func streamInferenceDetailed(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceDetailedResult {
        let resolved = try resolvedCapabilities(for: request, invocation: .streaming)
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: resolved.capabilities,
            invocation: resolved.invocation
        )
        let urlRequest = try makeRequest(request, streaming: true)
        let response: BoneInferenceEventStreamResponse
        do {
            response = try await transport.sendEventStream(urlRequest, options: options)
        } catch let error as BoneInferenceTransportError {
            if case let .httpStatus(statusCode) = error {
                throw BoneInferenceProviderResponseValidator.mappedError(statusCode: statusCode)
            }
            throw error
        }
        guard (200...299).contains(response.statusCode) else {
            throw BoneInferenceProviderResponseValidator.mappedError(statusCode: response.statusCode)
        }
        let finalResponse: BoneInferenceResponse
        if let constraint = request.outputConstraint {
            let aggregated = try BoneGeminiToolStreamAggregator.aggregate(
                events: response.events,
                definitions: []
            )
            guard case let .assistantTurn(turn, reason, _, refusal, _) = aggregated,
                  reason == .stop, refusal == nil, let text = turn.text else {
                throw BoneInferenceTransportError.invalidResponse
            }
            finalResponse = try BoneGeminiOutputConstraintAdapter().response(
                from: Data(text.utf8),
                constraint: constraint
            )
        } else if request.responseFormat.isStructured {
            guard request.availableTools.isEmpty else { throw BoneInferenceError.invalidStructuredOutputContract }
            let aggregated = try BoneGeminiToolStreamAggregator.aggregate(
                events: response.events,
                definitions: []
            )
            guard case let .assistantTurn(turn, reason, _, refusal, _) = aggregated,
                  reason == .stop, refusal == nil, let text = turn.text else {
                throw BoneInferenceTransportError.invalidResponse
            }
            finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                from: text,
                schema: request.responseFormat.schema?.root
            )
        } else {
            finalResponse = try BoneGeminiToolStreamAggregator.aggregate(
                events: response.events,
                definitions: request.availableTools
            )
        }
        return .init(
            response: finalResponse,
            reasoning: BoneInferenceReasoningSupport.gemini(
                events: response.events,
                disclosure: request.reasoningDisclosure
            )
        )
    }

    private func makeRequest(
        _ inferenceRequest: BoneInferenceRequest,
        streaming: Bool
    ) throws -> URLRequest {
        guard configuration.authenticationMode == .googleAPIKey else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        guard !inferenceRequest.messages.isEmpty else {
            throw BoneInferenceError.invalidMessage
        }
        if let continuation = inferenceRequest.providerContinuation {
            try continuation.validate(for: .google)
        }
        let options = try inferenceRequest.generationOptions.validated()
        let responseFormat = try inferenceRequest.responseFormat.validated()
        guard !responseFormat.isStructured || inferenceRequest.availableTools.isEmpty else {
            throw BoneInferenceError.invalidStructuredOutputContract
        }
        let modelID = inferenceRequest.modelID.hasPrefix("models/")
            ? String(inferenceRequest.modelID.dropFirst("models/".count))
            : inferenceRequest.modelID
        guard !modelID.isEmpty else { throw BoneInferenceError.invalidMessage }
        let method = streaming ? "streamGenerateContent" : "generateContent"
        let defaultPath = "/v1beta/models/{model}:\(method)"
        let configuredPath = configuration.endpointOverrides["chat"] ?? defaultPath
        let dynamicPath = configuredPath.replacingOccurrences(of: "{model}", with: modelID)
        var providerConfiguration = configuration
        if configuration.endpointOverrides["chat"] != dynamicPath {
            var overrides = configuration.endpointOverrides
            overrides["chat"] = dynamicPath
            providerConfiguration = .init(
                kind: configuration.kind,
                apiKey: configuration.apiKey,
                baseURL: configuration.baseURL,
                authenticationMode: configuration.authenticationMode,
                usesFullEndpointURL: configuration.usesFullEndpointURL,
                userAgent: configuration.userAgent,
                customHeaders: configuration.customHeaders,
                endpointOverrides: overrides,
                endpointSecurityPolicy: configuration.endpointSecurityPolicy
            )
        }
        var request = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: providerConfiguration,
            operation: "chat",
            defaultPath: dynamicPath,
            usesFullEndpointURL: true
        )
        if streaming {
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else {
                throw BoneInferenceTransportError.invalidEndpoint
            }
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "alt", value: "sse"))
            components.queryItems = queryItems
            guard let url = components.url else { throw BoneInferenceTransportError.invalidEndpoint }
            request.url = url
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        let systemMessages = inferenceRequest.messages.filter { $0.role == .system }
        let conversation = inferenceRequest.messages.filter { $0.role != .system }
        guard systemMessages.count <= 1,
              systemMessages.allSatisfy({ $0.content != nil }) else {
            throw BoneInferenceError.invalidMessage
        }
        let contents = try BoneGeminiToolWire.contents(
            conversation,
            definitions: inferenceRequest.availableTools,
            continuation: inferenceRequest.providerContinuation
        )
        var body: [String: Any] = [
            "contents": contents,
        ]
        if !inferenceRequest.availableTools.isEmpty {
            body["tools"] = try BoneGeminiToolWire.definitions(inferenceRequest.availableTools)
        }
        if let system = systemMessages.first?.content, !system.isEmpty {
            body["systemInstruction"] = ["parts": [["text": system]]]
        }
        var generationConfig = [String: Any]()
        if let temperature = options.temperature { generationConfig["temperature"] = temperature }
        if let maximumOutputTokens = options.maximumOutputTokens {
            generationConfig["maxOutputTokens"] = maximumOutputTokens
        }
        if let constraint = inferenceRequest.outputConstraint {
            let fields = try BoneGeminiOutputConstraintAdapter().requestFields(for: constraint)
            guard let constraintConfig = fields["generationConfig"] as? [String: Any] else {
                throw BoneInferenceError.invalidOutputConstraint
            }
            generationConfig.merge(constraintConfig) { _, _ in
                preconditionFailure("duplicate Gemini constraint field")
            }
        } else if responseFormat.isStructured {
            generationConfig["responseMimeType"] = "application/json"
            if let schema = try BoneStructuredOutputSupport.geminiSchema(responseFormat) {
                generationConfig["responseSchema"] = schema
            }
        }
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 返回当前官方 Gemini Constraint 执行组合的稳定验证身份；不包含凭据或完整 Endpoint。
    public func constraintVerificationIdentity(
        modelID: String,
        invocation: BoneInferenceInvocation
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        let adapter = BoneGeminiOutputConstraintAdapter()
        return try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .geminiGenerateContent,
            apiVersion: "v1beta",
            modelID: modelID,
            requestMapperID: "bone.gemini.generate-content",
            requestMapperVersion: "1",
            responseDecoderID: "bone.gemini.generate-content",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: invocation
        )
    }
}
