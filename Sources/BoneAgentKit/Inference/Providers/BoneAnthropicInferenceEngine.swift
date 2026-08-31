import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages 协议的通用推理实现。
public struct BoneAnthropicInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming,
    BoneInferenceDetailedResultProviding, BoneInferenceDetailedStreaming, BoneInferenceEventStreaming {
    public let nonImageCapabilities: Set<BoneInferenceCapability> = [.text, .toolCalling, .streaming]
    public let imageGenerator: (any BoneInferenceImageGenerating)? = nil

    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func infer(request: BoneInferenceRequest) async throws -> BoneInferenceResponse {
        try await inferDetailed(request: request).response
    }

    public func inferDetailed(
        request: BoneInferenceRequest
    ) async throws -> BoneInferenceDetailedResult {
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: capabilities,
            invocation: .nonStreaming
        )
        let prepared = try preparedRequest(request)
        let urlRequest = try makeRequest(prepared.request, streaming: false, forcedTool: prepared.tool)
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        let finalResponse: BoneInferenceResponse
        if let tool = prepared.tool {
            let parsed = try parseAnthropicToolResponse(json, definitions: [tool])
            finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                from: parsed,
                schema: request.responseFormat.schema?.root
            )
        } else if request.availableTools.isEmpty {
            finalResponse = .finish(
                .init(text: try BoneAnthropicResponseAggregator.nonStreamingText(from: json))
            )
        } else {
            finalResponse = try parseAnthropicToolResponse(json, definitions: request.availableTools)
        }
        return .init(
            response: finalResponse,
            reasoning: BoneInferenceReasoningSupport.anthropic(
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
                    try BoneInferenceCapabilityValidator.validate(
                        request: request,
                        capabilities: capabilities,
                        invocation: .streaming
                    )
                    let prepared = try preparedRequest(request)
                    let urlRequest = try makeRequest(prepared.request, streaming: true, forcedTool: prepared.tool)
                    var events: [BoneInferenceEventStreamEvent] = []
                    var mapper = BoneAnthropicNormalizedEventMapper(
                        disclosure: request.reasoningDisclosure,
                        definitions: prepared.request.availableTools
                    )
                    for try await event in transport.eventStream(urlRequest, options: options) {
                        events.append(event)
                        for mapped in try mapper.consume(event) { continuation.yield(mapped) }
                    }
                    let response: BoneInferenceResponse
                    if let tool = prepared.tool {
                        let parsed = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: [tool])
                        response = try BoneStructuredOutputSupport.structuredResponse(
                            from: parsed,
                            schema: request.responseFormat.schema?.root
                        )
                    } else if !request.availableTools.isEmpty {
                        response = try BoneAnthropicToolStreamAggregator.aggregate(events: events, definitions: request.availableTools)
                    } else {
                        response = .finish(
                            .init(text: try BoneAnthropicResponseAggregator.streamingText(from: events))
                        )
                    }
                    let result = BoneInferenceDetailedResult(
                        response: response,
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

    public func streamInferenceDetailed(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceDetailedResult {
        try BoneInferenceCapabilityValidator.validate(
            request: request,
            capabilities: capabilities,
            invocation: .streaming
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
        do {
            if let tool = prepared.tool {
                let parsed = try BoneAnthropicToolStreamAggregator.aggregate(
                    events: response.events,
                    definitions: [tool]
                )
                finalResponse = try BoneStructuredOutputSupport.structuredResponse(
                    from: parsed,
                    schema: request.responseFormat.schema?.root
                )
            } else if !request.availableTools.isEmpty {
                finalResponse = try BoneAnthropicToolStreamAggregator.aggregate(
                    events: response.events,
                    definitions: request.availableTools
                )
            } else {
                finalResponse = .finish(
                    .init(text: try BoneAnthropicResponseAggregator.streamingText(from: response.events))
                )
            }
        } catch BoneInferenceTransportError.invalidResponse {
            throw BoneInferenceProtocolShapeError(
                diagnostic: .anthropic(events: response.events)
            )
        }
        return .init(
            response: finalResponse,
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
        // MiniMax 目前无法保证原生 Schema 或单次强制 Tool；普通文本 JSON 不属于已声明回退契约。
        guard configuration.kind != .miniMax else {
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
        let messages = try BoneAnthropicToolWire.messages(
            conversationMessages,
            definitions: inferenceRequest.availableTools
        )
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
        if let temperature = options.temperature { body["temperature"] = temperature }
        if streaming { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
