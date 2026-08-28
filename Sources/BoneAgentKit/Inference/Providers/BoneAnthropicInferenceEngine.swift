import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Anthropic Messages 协议的通用推理实现。
public struct BoneAnthropicInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming {
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
        let urlRequest = try makeRequest(request, streaming: false)
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        if request.availableTools.isEmpty {
            return .finish(.init(text: try BoneAnthropicResponseAggregator.nonStreamingText(from: json)))
        }
        return try BoneAnthropicToolWire.parseResponse(json, definitions: request.availableTools)
    }

    public func streamInference(
        request: BoneInferenceRequest,
        options: BoneInferenceEventStreamOptions
    ) async throws -> BoneInferenceResponse {
        let urlRequest = try makeRequest(request, streaming: true)
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
        if !request.availableTools.isEmpty {
            return try BoneAnthropicToolStreamAggregator.aggregate(
                events: response.events,
                definitions: request.availableTools
            )
        }
        return .finish(.init(text: try BoneAnthropicResponseAggregator.streamingText(from: response.events)))
    }

    private func makeRequest(
        _ inferenceRequest: BoneInferenceRequest,
        streaming: Bool
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
        if let system = systemMessages.first?.content, !system.isEmpty { body["system"] = system }
        if let temperature = options.temperature { body["temperature"] = temperature }
        if streaming { body["stream"] = true }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
