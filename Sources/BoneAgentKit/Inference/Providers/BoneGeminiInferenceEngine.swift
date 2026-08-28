import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Gemini GenerateContent 协议的通用推理实现。
public struct BoneGeminiInferenceEngine: BoneInferenceEngine, BoneInferenceStreaming {
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
            return .finish(.init(text: try BoneGeminiResponseAggregator.text(from: json)))
        }
        return try BoneGeminiToolWire.parseResponse(json, definitions: request.availableTools)
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
            if case let .httpStatus(statusCode) = error {
                throw BoneInferenceProviderResponseValidator.mappedError(statusCode: statusCode)
            }
            throw error
        }
        guard (200...299).contains(response.statusCode) else {
            throw BoneInferenceProviderResponseValidator.mappedError(statusCode: response.statusCode)
        }
        return try BoneGeminiToolStreamAggregator.aggregate(
            events: response.events,
            definitions: request.availableTools
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
        if !generationConfig.isEmpty { body["generationConfig"] = generationConfig }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
