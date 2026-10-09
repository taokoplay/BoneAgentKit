import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages 协议的通用推理实现。
public struct BoneAnthropicInferenceEngine: BoneInferenceEngine, BoneInferenceBufferedStreaming,
    BoneInferenceDetailedResultProviding, BoneInferenceDetailedBufferedStreaming, BoneInferenceEventStreaming, BoneInferenceContextBudgetProviding, BoneInferenceContextRebinding {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [
        .text, .constrainedOutput, .toolCalling, .streaming,
    ]
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let allowsMiniMaxStructuredToolOutput: Bool

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
        allowsMiniMaxStructuredToolOutput: Bool = false,
        diagnostics: BoneInferenceDiagnosticSink = .init()
    ) {
        self.allowsMiniMaxStructuredToolOutput = allowsMiniMaxStructuredToolOutput
        self.modelMetadata = modelMetadata
        self.modelReasoningProfiles = modelReasoningProfiles
        self.modelContextLimits = modelContextLimits
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.transport = transport
        self.modelCapabilityProfiles = modelCapabilityProfiles
    }

    /// 查询当前请求与调用方式下的适配支持；不是远端模型成功率保证。
    /// nativeJSONSchema 对应 responseFormat；outputConstraint 仍用 resolvedCapabilities 查询。
    public func structuredOutputSupport(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneAnthropicStructuredOutputSupport {
        let resolved = try resolvedCapabilities(for: request, invocation: invocation)
        let callable = resolved.capabilities.contains(.text)
            && (invocation == .nonStreaming || resolved.capabilities.contains(.streaming))
        let tools = callable && resolved.capabilities.contains(.toolCalling)
        return .init(
            invocation: invocation,
            toolCalling: tools,
            nativeJSONSchema: false,
            toolOutput: tools && (configuration.kind != .miniMax || allowsMiniMaxStructuredToolOutput),
            forcedToolSelection: tools && configuration.kind != .miniMax
        )
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
        if profile?.continuation == .anthropicThinking && !request.responseFormat.isStructured && request.outputConstraint == nil {
            if let json { payload = try BoneThinkingContinuation.anthropicPayload(json: json) }
            else if let events { payload = try BoneThinkingContinuation.anthropicPayload(events: events) }
            else { payload = nil }
        } else { payload = nil }
        return try BoneThinkingContinuation.attach(response: response, payload: payload, request: request,
                                                    configuration: configuration, profiles: modelReasoningProfiles)
    }

    public func resolvedCapabilities(
        for request: BoneInferenceRequest,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneResolvedInferenceCapabilities {
        if let profile = modelReasoningProfiles[request.modelID],
           profile.continuation != .none && profile.continuation != .anthropicThinking {
            throw BoneInferenceReasoningConfigurationError.incompatibleProtocol
        }
        _ = try BoneThinkingContinuation.payloads(request: request, configuration: configuration, profiles: modelReasoningProfiles)
        var resolved = modelCapabilityProfiles[request.modelID]?
            .resolved(engineCapabilities: capabilities) ?? capabilities
        resolved.remove(.constrainedOutput)
        if let constraint = request.outputConstraint,
           configuration.kind == .anthropic,
           BoneAnthropicOutputConstraintAdapter().supports(constraint),
           let identity = try? constraintVerificationIdentity(modelID: request.modelID, invocation: invocation),
           BoneProviderVerificationIdentitySupport.isVerified(
               profile: modelCapabilityProfiles[request.modelID],
               currentIdentity: identity
           ) {
            resolved.insert(.constrainedOutput)
        }
        resolved = try BoneInferenceReasoningRequestSupport.resolved(
            resolved, request: request, metadata: modelMetadata[request.modelID],
            profile: modelReasoningProfiles[request.modelID], wire: .anthropic)
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
        let prepared = try preparedRequest(request)
        let urlRequest = try makeRequest(prepared.request, streaming: false, forcedTool: prepared.tool)
        try Task.checkCancellation()
        let diagnosticID = UUID()
        var receivedResponse = false
        diagnostics.emit(diagnosticID, .transportAttempt, wire: .anthropic)
        do {
            let response = try await transport.send(urlRequest)
            receivedResponse = true
            diagnostics.emit(diagnosticID, .httpResponseReceived, response: response, wire: .anthropic)
            try Task.checkCancellation()
            let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
            let finalResponse: BoneInferenceResponse
            if let constraint = request.outputConstraint {
                let text = try BoneAnthropicResponseAggregator.nonStreamingText(from: json)
                finalResponse = try BoneAnthropicOutputConstraintAdapter().response(
                    from: Data(text.utf8),
                    constraint: constraint
                )
            } else if let tool = prepared.tool {
                let parsed = try parseAnthropicToolResponse(json, definitions: [tool])
                finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                    from: parsed,
                    schema: request.responseFormat.schema?.root,
                    allowsTextFallback: configuration.kind != .miniMax
                )
            } else if request.availableTools.isEmpty {
                if modelReasoningProfiles[request.modelID]?.continuation == .anthropicThinking {
                    // Preserve separate public text blocks so the exact assistant turn can be
                    // checked before opaque thinking blocks are replayed on the next request.
                    finalResponse = try parseAnthropicToolResponse(json, definitions: [])
                } else {
                    finalResponse = .finish(
                        .init(text: try BoneAnthropicResponseAggregator.nonStreamingText(from: json))
                    )
                }
            } else {
                finalResponse = try parseAnthropicToolResponse(json, definitions: request.availableTools)
            }
            diagnostics.emit(diagnosticID, .resultValidated, wire: .anthropic)
            return .init(
                response: try retainingThinking(finalResponse.retainingUsage(BoneProviderUsage.read(json, wire: .anthropic)), request: request, json: json),
                reasoning: BoneInferenceReasoningSupport.anthropic(
                    json: json,
                    disclosure: request.reasoningDisclosure
                )
            )
        } catch {
            diagnostics.emit(diagnosticID, receivedResponse ? .responseValidationFailed : .transportFailed, wire: .anthropic)
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
                    var mapper = BoneAnthropicNormalizedEventMapper(
                        disclosure: request.reasoningDisclosure,
                        definitions: prepared.request.availableTools
                    )
                    try Task.checkCancellation()
                    for try await event in transport.eventStream(urlRequest, options: options) {
                        events.append(event)
                        let mappedEvents = try mapper.consume(event)
                        if request.outputConstraint == nil {
                            for mapped in mappedEvents { continuation.yield(mapped) }
                        }
                    }
                    let response: BoneInferenceResponse
                    if let constraint = request.outputConstraint {
                        let parsed = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: [])
                        guard case let .assistantTurn(turn, reason, _, refusal, _) = parsed,
                              reason == .stop, refusal == nil, let text = turn.text else {
                            throw BoneInferenceTransportError.invalidResponse
                        }
                        response = try BoneAnthropicOutputConstraintAdapter().response(
                            from: Data(text.utf8),
                            constraint: constraint
                        )
                    } else if let tool = prepared.tool {
                        let parsed = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: [tool])
                        response = try BoneStructuredOutputSupport.structuredResponse(
                            from: parsed,
                            schema: request.responseFormat.schema?.root,
                            allowsTextFallback: configuration.kind != .miniMax
                        )
                    } else if !request.availableTools.isEmpty {
                        response = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: request.availableTools)
                    } else {
                        if modelReasoningProfiles[request.modelID]?.continuation == .anthropicThinking {
                            response = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: [])
                        } else {
                            response = .finish(
                                .init(text: try BoneAnthropicResponseAggregator.streamingText(from: events))
                            )
                        }
                    }
                    let result = BoneInferenceDetailedResult(
                        response: try retainingThinking(response.retainingUsage(BoneProviderUsage.read(events, wire: .anthropic)), request: request, events: events),
                        reasoning: BoneInferenceReasoningSupport.anthropic(
                            events: events,
                            disclosure: request.reasoningDisclosure
                        )
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
            try Task.checkCancellation()
            response = try await transport.sendEventStream(urlRequest, options: options)
            try Task.checkCancellation()
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
        do {
            if let constraint = request.outputConstraint {
                let parsed = try BoneAnthropicToolStreamAggregator.aggregate(events: response.events, definitions: [])
                guard case let .assistantTurn(turn, reason, _, refusal, _) = parsed,
                      reason == .stop, refusal == nil, let text = turn.text else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                finalResponse = try BoneAnthropicOutputConstraintAdapter().response(
                    from: Data(text.utf8),
                    constraint: constraint
                )
            } else if let tool = prepared.tool {
                let parsed = try BoneAnthropicToolStreamAggregator.aggregate(
                    events: response.events,
                    definitions: [tool]
                )
                finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                    from: parsed,
                    schema: request.responseFormat.schema?.root,
                    allowsTextFallback: configuration.kind != .miniMax
                )
            } else if !request.availableTools.isEmpty {
                finalResponse = try BoneAnthropicToolStreamAggregator.aggregate(
                    events: response.events,
                    definitions: request.availableTools
                )
            } else {
                if modelReasoningProfiles[request.modelID]?.continuation == .anthropicThinking {
                    finalResponse = try BoneAnthropicToolStreamAggregator.aggregate(
                        events: response.events,
                        definitions: []
                    )
                } else {
                    finalResponse = .finish(
                        .init(text: try BoneAnthropicResponseAggregator.streamingText(from: response.events))
                    )
                }
            }
        } catch BoneInferenceTransportError.invalidResponse {
            throw BoneInferenceProtocolShapeError(
                diagnostic: .anthropic(events: response.events)
            )
        }
        return .init(
            response: try retainingThinking(finalResponse.retainingUsage(BoneProviderUsage.read(response.events, wire: .anthropic)), request: request, events: response.events),
            reasoning: BoneInferenceReasoningSupport.anthropic(
                events: response.events,
                disclosure: request.reasoningDisclosure
            )
        )
    }

    private func parseAnthropicToolResponse(
        _ json: [String: Any],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        do {
            return try BoneAnthropicToolWire.parseResponse(json, definitions: definitions)
        } catch BoneInferenceTransportError.invalidResponse {
            throw BoneInferenceProtocolShapeError(
                diagnostic: .anthropic(
                    responseJSON: json,
                    failureStage: BoneAnthropicToolWire.failureStage(json, definitions: definitions)
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
        guard format.fallbackPolicy == .nativeOrToolCall else {
            throw BoneInferenceError.unsupportedStructuredOutput
        }
        // auto 不保证调用结果 Tool；显式启用后仅接受严格单次 Tool 结果。
        guard try structuredOutputSupport(for: request, invocation: .nonStreaming).toolOutput else {
            throw BoneInferenceError.unsupportedStructuredOutput
        }
        let tool = try BoneStructuredOutputSupport.fallbackTool(for: format)
        let prepared = BoneInferenceRequest(
            modelID: request.modelID,
            messages: request.messages,
            availableTools: [tool],
            generationOptions: request.generationOptions,
            responseFormat: .text,
            providerContinuation: request.providerContinuation,
            reasoningDisclosure: request.reasoningDisclosure
        )
        return (prepared, tool)
    }

    private func makeRequest(
        _ inferenceRequest: BoneInferenceRequest,
        streaming: Bool,
        forcedTool: BoneAgentToolDefinition? = nil
    ) throws -> URLRequest {
        guard configuration.authenticationMode != .googleAPIKey else {
            throw BoneInferenceTransportError.invalidConfiguration
        }
        guard !inferenceRequest.messages.isEmpty else {
            throw BoneInferenceError.invalidMessage
        }
        let options = try inferenceRequest.generationOptions.validated()
        var request = try BoneInferenceProviderRequestBuilder.makeJSONRequest(
            configuration: configuration,
            operation: "chat",
            defaultPath: "/v1/messages",
            usesFullEndpointURL: true,
            fixedHeaders: ["anthropic-version": "2023-06-01"]
        )
        if streaming { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }

        let systemMessages = inferenceRequest.messages.filter { $0.role == .system }
        let conversationMessages = inferenceRequest.messages.filter { $0.role != .system }
        guard systemMessages.count <= 1,
              systemMessages.allSatisfy({ $0.content != nil }) else {
            throw BoneInferenceError.invalidMessage
        }
        var messages = try BoneAnthropicToolWire.messages(
            conversationMessages,
            definitions: inferenceRequest.availableTools
        )
        let privatePayloads = try BoneThinkingContinuation.payloads(request: inferenceRequest, configuration: configuration, profiles: modelReasoningProfiles)
        for (index, payload) in privatePayloads {
            guard messages.indices.contains(index), conversationMessages[index].assistantTurn != nil,
                  let blocks = try JSONSerialization.jsonObject(with: payload) as? [[String: Any]] else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            _ = try BoneThinkingContinuation.anthropicPayload(json: ["content": blocks])
            // Check public text/tool identity against the immutable turn before echoing opaque blocks.
            let check = try BoneAnthropicToolWire.parseResponse([
                "content": blocks,
                "stop_reason": conversationMessages[index].assistantTurn!.toolCalls.isEmpty ? "end_turn" : "tool_use"
            ], definitions: inferenceRequest.availableTools)
            guard check.terminalAssistantTurn == conversationMessages[index].assistantTurn else {
                throw BoneInferenceError.invalidProviderContinuation
            }
            messages[index]["content"] = blocks
        }
        var body: [String: Any] = [
            "model": inferenceRequest.modelID,
            "messages": messages,
            "max_tokens": options.maximumOutputTokens ?? 4096,
        ]
        if !inferenceRequest.availableTools.isEmpty {
            body["tools"] = try BoneAnthropicToolWire.definitions(inferenceRequest.availableTools)
        }
        if let forcedTool {
            if configuration.kind == .miniMax {
                // MiniMax Anthropic 兼容 OpenAPI 仅支持 auto/none；type=tool 会被忽略并退化为文本。
                body["tool_choice"] = ["type": "auto"]
            } else {
                body["tool_choice"] = ["type": "tool", "name": forcedTool.wireName!]
            }
        }
        if let system = systemMessages.first?.content, !system.isEmpty { body["system"] = system }
        if let constraint = inferenceRequest.outputConstraint {
            let fields = try BoneAnthropicOutputConstraintAdapter().requestFields(for: constraint)
            body.merge(fields) { _, _ in preconditionFailure("duplicate Anthropic constraint field") }
        }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if streaming { body["stream"] = true }
        try BoneInferenceReasoningRequestSupport.merge(
            BoneInferenceReasoningRequestSupport.fields(request: inferenceRequest,
                profile: modelReasoningProfiles[inferenceRequest.modelID], wire: .anthropic, forcedTool: forcedTool != nil), into: &body)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// 返回当前官方 Anthropic Constraint 执行组合的稳定验证身份；不包含凭据或完整 Endpoint。
    public func constraintVerificationIdentity(
        modelID: String,
        invocation: BoneInferenceInvocationMode
    ) throws -> BoneProviderCapabilityVerificationIdentity {
        let adapter = BoneAnthropicOutputConstraintAdapter()
        return try BoneProviderVerificationIdentitySupport.identity(
            configuration: configuration,
            protocolVariant: .anthropicMessages,
            apiVersion: "2023-06-01",
            modelID: modelID,
            requestMapperID: "bone.anthropic.messages",
            requestMapperVersion: "1",
            responseDecoderID: "bone.anthropic.messages",
            responseDecoderVersion: "1",
            constraintDialectID: adapter.identity.id,
            constraintDialectVersion: adapter.identity.version,
            invocation: invocation
        )
    }
}
