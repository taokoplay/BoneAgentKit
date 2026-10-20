import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Chat Completions 及兼容协议的通用推理实现。
public struct BoneOpenAIInferenceEngine: BoneInferenceEngine, BoneInferenceBufferedStreaming,
    BoneInferenceDetailedResultProviding, BoneInferenceDetailedBufferedStreaming, BoneInferenceEventStreaming, BoneInferenceContextBudgetProviding, BoneInferenceContextRebinding {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [
        .text, .structuredOutput, .constrainedOutput, .toolCalling, .streaming,
    ]
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let serverReasoning: BoneInferenceServerReasoning
    private let requestsStreamingUsage: Bool
    private let verifiedThinkingModelIDs: Set<String>
    private let modelContextLimits: [String: BoneModelContextLimits]

    public func contextBudget(for modelID: String) throws -> BoneContextWindowBudget? {
        modelContextLimits[modelID]?.contextWindowBudget
    }

    private let configuration: BoneInferenceProviderConfiguration
    private let diagnostics: BoneInferenceDiagnosticSink
    private let transport: any BoneInferenceHTTPTransport
    private let modelCapabilityProfiles: [String: BoneModelCapabilityProfile]
    private let modelMetadata: [String: BoneModelMetadata]
    private let modelReasoningProfiles: [String: BoneInferenceReasoningProfile]

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport,
        modelCapabilityProfiles: [String: BoneModelCapabilityProfile] = [:],
        modelContextLimits: [String: BoneModelContextLimits] = [:],
        modelMetadata: [String: BoneModelMetadata] = [:],
        modelReasoningProfiles: [String: BoneInferenceReasoningProfile] = [:],
        diagnostics: BoneInferenceDiagnosticSink = .init(),
        serverReasoning: BoneInferenceServerReasoning = .providerDefault,
        verifiedThinkingModelIDs: Set<String> = [],
        requestsStreamingUsage: Bool = true
    ) {
        self.requestsStreamingUsage = requestsStreamingUsage
        self.serverReasoning = serverReasoning
        self.verifiedThinkingModelIDs = verifiedThinkingModelIDs
        self.modelMetadata = modelMetadata
        self.modelReasoningProfiles = modelReasoningProfiles
        self.modelContextLimits = modelContextLimits
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.transport = transport
        self.modelCapabilityProfiles = modelCapabilityProfiles
    }

    /// Host 核验集合需与此实例的站点、模型绑定；不由模型发现结果自动赋予。
    /// 当前仅 Agnes OpenAI 兼容格式有 enabled 映射，disabled 尚无已核实契约。
    public func supportedServerReasoning(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> Set<BoneInferenceServerReasoning> {
        let resolved = try resolvedCapabilities(for: request, invocation: invocation)
        var supported: Set<BoneInferenceServerReasoning> = [.providerDefault]
        if configuration.kind == .agnes,
           verifiedThinkingModelIDs.contains(request.modelID),
           resolved.capabilities.contains(.text),
           invocation == .nonStreaming || resolved.capabilities.contains(.streaming) {
            supported.insert(.enabled)
        }
        return supported
    }

    public func rebindContextContinuation(_ continuation: BoneInferenceProviderContinuation,
                                          from original: [BoneInferenceMessage], to compacted: [BoneInferenceMessage]) throws -> BoneInferenceProviderContinuation? {
        try BoneThinkingContinuation.rebind(continuation, configuration: configuration,
                                           profiles: modelReasoningProfiles, from: original, to: compacted)
    }

    private func retainingThinking(_ response: BoneInferenceResponse, request: BoneInferenceRequest,
                                   json: [String: Any]? = nil,
                                   events: [BoneInferenceEventStreamEvent]? = nil) throws -> BoneInferenceResponse {
        let profile = modelReasoningProfiles[request.modelID]
        let payload: Data?
        if profile?.continuation == .reasoningContent && !request.responseFormat.isStructured && request.outputConstraint == nil {
            if let json { payload = try BoneThinkingContinuation.openAIPayload(json: json) }
            else if let events { payload = try BoneThinkingContinuation.openAIPayload(events: events) }
            else { payload = nil }
        } else { payload = nil }
        return try BoneThinkingContinuation.attach(response: response, payload: payload, request: request,
                                                    configuration: configuration, profiles: modelReasoningProfiles)
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities {
        if serverReasoning != .providerDefault, request.generationOptions.reasoning != nil {
            throw BoneInferenceReasoningConfigurationError.conflictingLegacySetting
        }
        if let profile = modelReasoningProfiles[request.modelID],
           profile.continuation != .none && profile.continuation != .reasoningContent {
            throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
        }
        _ = try BoneThinkingContinuation.payloads(request: request, configuration: configuration, profiles: modelReasoningProfiles)
        var resolved = capabilities
        // 兼容网关只承诺 OpenAI wire shape，不据此承诺官方原生约束。
        if configuration.kind != .openAI {
            resolved.remove(.structuredOutput)
        }
        if let profile = modelCapabilityProfiles[request.modelID] {
            resolved = profile.resolved(engineCapabilities: resolved)
        }
        resolved.remove(.constrainedOutput)
        if let constraint = request.outputConstraint,
           configuration.kind == .openAI,
           BoneOpenAIOutputConstraintAdapter().supports(constraint),
           let identity = try? constraintVerificationIdentity(modelID: request.modelID, invocation: invocation),
           BoneProviderVerificationIdentitySupport.isVerified(
               profile: modelCapabilityProfiles[request.modelID],
               currentIdentity: identity
           ) {
            resolved.insert(.constrainedOutput)
        }
        resolved = try BoneInferenceReasoningRequestSupport.resolved(
            resolved, request: request, metadata: modelMetadata[request.modelID],
            profile: modelReasoningProfiles[request.modelID], wire: .openAI)
        return .init(
            modelID: request.modelID,
            invocation: invocation,
            capabilities: resolved
        )
    }

    public func infer(
        request: BoneInferenceRequest
    ) async throws -> BoneInferenceResponse {
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
        let prepared = try preparedRequest(request)
        let urlRequest = try makeRequest(prepared.request, streaming: false, forcedTool: prepared.tool)
        let diagnosticID = UUID()
        var receivedResponse = false
        var failureStage: BoneInferenceDiagnosticEvent.FailureStage = .transport
        diagnostics.emit(diagnosticID, .transportAttempt, wire: .openAI)
        do {
            let response = try await transport.send(urlRequest)
            receivedResponse = true
            diagnostics.emit(diagnosticID, .httpResponseReceived, response: response, wire: .openAI)
            failureStage = (200...299).contains(response.statusCode) ? .jsonDecoding : .httpStatus
            let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
            failureStage = .resultValidation
            let finalResponse: BoneInferenceResponse
            if let constraint = request.outputConstraint {
                let text = try BoneOpenAIResponseAggregator.nonStreamingText(
                    from: json,
                    requiringSingleCompletedChoice: true
                )
                finalResponse = try BoneOpenAIOutputConstraintAdapter().response(
                    from: Data(text.utf8),
                    constraint: constraint
                )
            } else if let tool = prepared.tool {
                let parsed = try parseOpenAIToolResponse(json, definitions: [tool])
                finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                    from: parsed,
                    schema: request.responseFormat.schema?.root
                )
            } else if request.responseFormat.isStructured {
                guard request.availableTools.isEmpty else { throw BoneInferenceError.invalidStructuredOutputContract }
                let text = try BoneOpenAIResponseAggregator.nonStreamingText(from: json)
                finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                    from: text,
                    schema: request.responseFormat.schema?.root
                )
            } else if request.availableTools.isEmpty {
                let text = try BoneOpenAIResponseAggregator.nonStreamingText(from: json)
                finalResponse = .finish(.init(text: text))
            } else {
                finalResponse = try parseOpenAIToolResponse(json, definitions: request.availableTools)
            }
            let result = BoneInferenceDetailedResult(
                response: try retainingThinking(finalResponse.retainingUsage(BoneProviderUsage.read(json, wire: .openAI)), request: request, json: json),
                reasoning: BoneInferenceReasoningSupport.openAI(
                    json: json,
                    disclosure: request.reasoningDisclosure
                )
            )
            diagnostics.emit(diagnosticID, .resultValidated, wire: .openAI)
            return result
        } catch {
            diagnostics.emit(diagnosticID, receivedResponse ? .responseValidationFailed : .transportFailed, wire: .openAI, failureStage: failureStage)
            throw error
        }
    }

    public func inferUsingStream(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse {
        try await inferDetailedUsingStream(request: request, options: options).response
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
                    let prepared = try preparedRequest(request)
                    let urlRequest = try makeRequest(prepared.request, streaming: true, forcedTool: prepared.tool)
                    var events: [BoneInferenceEventStreamEvent] = []
                    var mapper = BoneOpenAINormalizedEventMapper(
                        disclosure: request.reasoningDisclosure,
                        definitions: prepared.request.availableTools
                    )
                    for try await event in transport.eventStream(urlRequest, options: options) {
                        events.append(event)
                        let mappedEvents = try mapper.consume(event)
                        if request.outputConstraint == nil {
                            for mapped in mappedEvents { continuation.yield(mapped) }
                        }
                    }
                    let response: BoneInferenceResponse
                    if let constraint = request.outputConstraint {
                        let text = try BoneOpenAIResponseAggregator.streamingText(
                            from: events,
                            requiringSingleCompletedChoice: true
                        )
                        response = try BoneOpenAIOutputConstraintAdapter().response(
                            from: Data(text.utf8),
                            constraint: constraint
                        )
                    } else if let tool = prepared.tool {
                        let parsed = try BoneOpenAIToolStreamAggregator.aggregate(events: events, definitions: [tool])
                        response = try BoneStructuredOutputSupport.structuredResponse(from: parsed, schema: request.responseFormat.schema?.root)
                    } else if request.responseFormat.isStructured {
                        response = try BoneStructuredOutputSupport.structuredResponse(
                            from: BoneOpenAIResponseAggregator.streamingText(from: events),
                            schema: request.responseFormat.schema?.root
                        )
                    } else if !request.availableTools.isEmpty {
                        response = try BoneOpenAIToolStreamAggregator.aggregate(events: events, definitions: request.availableTools)
                    } else {
                        response = .finish(.init(text: try BoneOpenAIResponseAggregator.streamingText(from: events)))
                    }
                    let result = BoneInferenceDetailedResult(
                        response: try retainingThinking(response.retainingUsage(BoneProviderUsage.read(events, wire: .openAI)), request: request, events: events),
                        reasoning: BoneInferenceReasoningSupport.openAI(events: events, disclosure: request.reasoningDisclosure)
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func inferDetailedUsingStream(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceDetailedResult {
        let resolved = try resolvedCapabilities(for: request, invocation: .streaming)
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: resolved.capabilities,
            invocation: resolved.invocation
        )
        let prepared = try preparedRequest(request)
        let urlRequest = try makeRequest(prepared.request, streaming: true, forcedTool: prepared.tool)
        let response: BoneInferenceEventStreamResponse
        do {
            response = try await transport.sendEventStream(urlRequest, options: options)
        } catch let error as BoneInferenceTransportError {
            if case .httpStatus(let statusCode) = error {
                throw BoneInferenceProviderResponseValidator.mappedError(statusCode: statusCode)
            }
            throw error
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw BoneInferenceProviderResponseValidator.mappedError(statusCode: response.statusCode)
        }
        let finalResponse: BoneInferenceResponse
        if let constraint = request.outputConstraint {
            let text = try BoneOpenAIResponseAggregator.streamingText(
                from: response.events,
                requiringSingleCompletedChoice: true
            )
            finalResponse = try BoneOpenAIOutputConstraintAdapter().response(
                from: Data(text.utf8),
                constraint: constraint
            )
        } else if let tool = prepared.tool {
            let parsed = try parseOpenAIToolStream(response.events, definitions: [tool])
            finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                from: parsed,
                schema: request.responseFormat.schema?.root
            )
        } else if request.responseFormat.isStructured {
            guard request.availableTools.isEmpty else { throw BoneInferenceError.invalidStructuredOutputContract }
            let text = try BoneOpenAIResponseAggregator.streamingText(from: response.events)
            finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                from: text,
                schema: request.responseFormat.schema?.root
            )
        } else if !request.availableTools.isEmpty {
            finalResponse = try parseOpenAIToolStream(
                response.events,
                definitions: request.availableTools
            )
        } else {
            let text = try BoneOpenAIResponseAggregator.streamingText(from: response.events)
            finalResponse = .finish(.init(text: text))
        }
        return .init(
            response: try retainingThinking(finalResponse.retainingUsage(BoneProviderUsage.read(response.events, wire: .openAI)), request: request, events: response.events),
            reasoning: BoneInferenceReasoningSupport.openAI(
                events: response.events,
                disclosure: request.reasoningDisclosure
            )
        )
    }

    private func parseOpenAIToolStream(
        _ events: [BoneInferenceEventStreamEvent],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        do {
            return try BoneOpenAIToolStreamAggregator.aggregate(events: events, definitions: definitions)
        } catch BoneInferenceTransportError.invalidResponse {
            throw BoneInferenceProtocolShapeError(
                diagnostic: .openAI(
                    events: events,
                    failureStage: BoneOpenAIToolStreamAggregator.failureStage(
                        events: events,
                        definitions: definitions
                    )
                )
            )
        }
    }

    private func parseOpenAIToolResponse(
        _ json: [String: Any],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        do {
            return try BoneOpenAIToolWire.parseResponse(json, definitions: definitions)
        } catch BoneInferenceTransportError.invalidResponse {
            throw BoneInferenceProtocolShapeError(
                diagnostic: .openAI(
                    responseJSON: json,
                    failureStage: BoneOpenAIToolWire.failureStage(json, definitions: definitions)
                )
            )
        }
    }

    private func preparedRequest(
        _ request: BoneInferenceRequest
    ) throws -> (request: BoneInferenceRequest, tool: BoneAgentToolDefinition?) {
        let format = try request.responseFormat.validated()
        guard format.isStructured else { return (request, nil) }
        guard request.availableTools.isEmpty else {
            throw BoneInferenceError.invalidStructuredOutputContract
        }
        // 只有官方 OpenAI 实例使用原生 response_format；兼容网关不按同协议名称猜能力。
        guard configuration.kind != .openAI else { return (request, nil) }
        guard format.fallbackPolicy == .nativeOrToolCall else {
            throw BoneInferenceError.unsupportedStructuredOutput
        }
        let tool = try BoneStructuredOutputSupport.fallbackTool(for: format)
        return (
            BoneInferenceRequest(
                modelID: request.modelID,
                messages: request.messages,
                availableTools: [tool],
                generationOptions: request.generationOptions,
                responseFormat: .text,
                providerContinuation: request.providerContinuation,
                reasoningDisclosure: request.reasoningDisclosure
            ),
            tool
        )
    }

    private func makeRequest(
        _ inferenceRequest: BoneInferenceRequest,
        streaming: Bool,
        forcedTool: BoneAgentToolDefinition? = nil
    ) throws -> URLRequest {
        guard try supportedServerReasoning(for: inferenceRequest, invocation: streaming ? .streaming : .nonStreaming).contains(serverReasoning) else {
            throw BoneInferenceUnsupportedServerReasoning(requested: serverReasoning)
        }
        guard !inferenceRequest.messages.isEmpty else {
            throw BoneInferenceError.invalidMessage
        }
        let responseFormat = try inferenceRequest.responseFormat.validated()
        guard !responseFormat.isStructured || inferenceRequest.availableTools.isEmpty else {
            throw BoneInferenceError.invalidStructuredOutputContract
        }
        var messages = try BoneOpenAIToolWire.messages(
            inferenceRequest.messages,
            definitions: inferenceRequest.availableTools
        )
        let privatePayloads = try BoneThinkingContinuation.payloads(request: inferenceRequest, configuration: configuration, profiles: modelReasoningProfiles)
        var semanticIndex = 0
        var wireIndex = 0
        for message in inferenceRequest.messages {
            if message.role != .system {
                if let payload = privatePayloads[semanticIndex] {
                    guard let fields = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                          fields.count == 1, let reasoning = fields["reasoning_content"] as? String,
                          messages.indices.contains(wireIndex), message.assistantTurn != nil else {
                        throw BoneInferenceError.invalidProviderContinuation
                    }
                    messages[wireIndex]["reasoning_content"] = reasoning
                }
                semanticIndex += 1
            }
            wireIndex += message.role == .tool ? try message.requiredToolResults().results.count : 1
        }
        let options = try inferenceRequest.generationOptions.validated()
        let defaultPath = configuration.kind == .zhipu
            ? "/api/paas/v4/chat/completions"
            : "/v1/chat/completions"
        var request = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: configuration,
            operation: "chat",
            defaultPath: defaultPath,
            usesFullEndpointURL: true
        )
        if streaming {
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        }
        var body: [String: Any] = [
            "model": inferenceRequest.modelID,
            "messages": messages,
        ]
        if serverReasoning != .providerDefault, inferenceRequest.generationOptions.reasoning != nil {
            throw BoneInferenceReasoningConfigurationError.conflictingLegacySetting
        }
        if serverReasoning == .enabled {
            body["chat_template_kwargs"] = ["enable_thinking": true]
        }
        if !inferenceRequest.availableTools.isEmpty {
            body["tools"] = try BoneOpenAIToolWire.definitions(inferenceRequest.availableTools)
        }
        if let forcedTool {
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": forcedTool.wireName!],
            ]
        }
        if let constraint = inferenceRequest.outputConstraint {
            let fields = try BoneOpenAIOutputConstraintAdapter().requestFields(for: constraint)
            body.merge(fields) { _, _ in preconditionFailure("duplicate OpenAI constraint field") }
        } else if let nativeFormat = try BoneStructuredOutputSupport.nativeWireFormat(responseFormat) {
            body["response_format"] = nativeFormat
        }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let maximumOutputTokens = options.maximumOutputTokens {
            let usesCompletionTokens = modelReasoningProfiles[inferenceRequest.modelID]?.wireFormat == .openAIChat
            body[usesCompletionTokens ? "max_completion_tokens" : "max_tokens"] = maximumOutputTokens
        }
        if streaming {
            body["stream"] = true
            if requestsStreamingUsage { body["stream_options"] = ["include_usage": true] }
        }
        try BoneInferenceReasoningRequestSupport.merge(
            BoneInferenceReasoningRequestSupport.fields(request: inferenceRequest,
                profile: modelReasoningProfiles[inferenceRequest.modelID], wire: .openAI, forcedTool: forcedTool != nil), into: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 返回当前官方 OpenAI Constraint 执行组合的稳定验证身份；不包含凭据或完整 Endpoint。
    public func constraintVerificationIdentity(
        modelID: String,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        let adapter = BoneOpenAIOutputConstraintAdapter()
        return try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .openAI,
            apiVersion: "v1",
            modelID: modelID,
            requestMapperID: "bone.openai.chat-completions",
            requestMapperVersion: "1",
            responseDecoderID: "bone.openai.chat-completions",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: invocation
        )
    }
}
