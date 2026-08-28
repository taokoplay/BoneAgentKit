import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// OpenAI Chat Completions 及兼容协议的通用推理实现。
public struct BoneOpenAIInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming {
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

    public func infer(
        request: BoneInferenceRequest
    ) async throws -> BoneInferenceResponse {
        let urlRequest = try makeRequest(request, streaming: false)
        let response = try await transport.send(urlRequest)
        let json = try BoneInferenceProviderResponseValidator.validatedJSONObject(response)
        if request.availableTools.isEmpty {
            let text = try BoneOpenAIResponseAggregator.nonStreamingText(from: json)
            return .finish(.init(text: text))
        }
        return try BoneOpenAIToolWire.parseResponse(json, definitions: request.availableTools)
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
            return try BoneOpenAIToolStreamAggregator.aggregate(
                events: response.events,
                definitions: request.availableTools
            )
        }
        let text = try BoneOpenAIResponseAggregator.streamingText(from: response.events)
        return .finish(.init(text: text))
    }

    private func makeRequest(
        _ inferenceRequest: BoneInferenceRequest,
        streaming: Bool
    ) throws -> URLRequest {
        guard !inferenceRequest.messages.isEmpty else {
            throw BoneInferenceError.invalidMessage
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
