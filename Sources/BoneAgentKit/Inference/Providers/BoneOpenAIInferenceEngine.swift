import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Chat Completions 及兼容协议的通用推理实现。
public struct BoneOpenAIInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming,
    BoneInferenceDetailedResultProviding, BoneInferenceDetailedStreaming, BoneInferenceEventStreaming {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [
        .text, .structuredOutput, .toolCalling, .streaming,
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
        var resolved = capabilities
        // 兼容网关只承诺 OpenAI wire shape，不据此承诺原生 response_format。
        if configuration.kind != .openAI {
            resolved.remove(.structuredOutput)
        }
        if let profile = modelCapabilityProfiles[request.modelID] {
            resolved = profile.resolved(engineCapabilities: resolved)
        }
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
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        let finalResponse: BoneInferenceResponse
        if let tool = prepared.tool {
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
        return .init(
            response: finalResponse,
            reasoning: BoneInferenceReasoningSupport.openAI(
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
                    let prepared = try preparedRequest(request)
                    let urlRequest = try makeRequest(prepared.request, streaming: true, forcedTool: prepared.tool)
                    var events: [BoneInferenceEventStreamEvent] = []
                    var mapper = BoneOpenAINormalizedEventMapper(
                        disclosure: request.reasoningDisclosure,
                        definitions: prepared.request.availableTools
                    )
                    for try await event in transport.eventStream(urlRequest, options: options) {
                        events.append(event)
                        for mapped in try mapper.consume(event) { continuation.yield(mapped) }
                    }
                    let response: BoneInferenceResponse
                    if let tool = prepared.tool {
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
                        response: response,
                        reasoning: BoneInferenceReasoningSupport.openAI(events: events, disclosure: request.reasoningDisclosure)
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
        if let tool = prepared.tool {
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
            response: finalResponse,
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
        guard !inferenceRequest.messages.isEmpty else {
            throw BoneInferenceError.invalidMessage
        }
        let responseFormat = try inferenceRequest.responseFormat.validated()
        guard !responseFormat.isStructured || inferenceRequest.availableTools.isEmpty else {
            throw BoneInferenceError.invalidStructuredOutputContract
        }
        let messages = try BoneOpenAIToolWire.messages(
            inferenceRequest.messages,
            definitions: inferenceRequest.availableTools
        )
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
        if !inferenceRequest.availableTools.isEmpty {
            body["tools"] = try BoneOpenAIToolWire.definitions(inferenceRequest.availableTools)
        }
        if let forcedTool {
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": forcedTool.wireName!],
            ]
        }
        if let nativeFormat = try BoneStructuredOutputSupport.nativeWireFormat(responseFormat) {
            body["response_format"] = nativeFormat
        }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if let maximumOutputTokens = options.maximumOutputTokens {
            body["max_tokens"] = maximumOutputTokens
        }
        if streaming {
            body["stream"] = true
            if !inferenceRequest.availableTools.isEmpty {
                body["stream_options"] = ["include_usage": true]
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
