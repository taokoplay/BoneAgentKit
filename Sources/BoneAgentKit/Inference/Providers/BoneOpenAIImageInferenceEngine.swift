import Foundation

/// OpenAI Images 兼容协议，亦适用于使用相同 data/images 响应形态的服务。
public struct BoneOpenAIImageInferenceEngine: BoneInferenceImageGenerating {
    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport
    private let defaultPath: String

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport(),
        defaultPath: String = "/v1/images/generations"
    ) {
        self.configuration = configuration
        self.transport = transport
        self.defaultPath = defaultPath
    }

    public func generateImages(
        request: BoneInferenceImageGenerationRequest
    ) async throws -> BoneInferenceImageGenerationResponse {
        let httpRequest = try BoneImageInferenceProviderSupport.makeRequest(
            configuration: configuration,
            path: configuration.endpointOverrides["image"] ?? defaultPath,
            authentication: .bearer,
            body: [
                "model": request.modelID,
                "prompt": request.prompt,
                "n": request.count.value,
                "size": request.size.openAIValue,
            ]
        )
        let json = try BoneImageInferenceProviderSupport.validatedJSON(
            try await transport.send(httpRequest)
        )
        let entries = (json["data"] as? [[String: Any]])
            ?? (json["images"] as? [[String: Any]])
            ?? []
        let payloads = try entries.compactMap {
            try BoneImageInferenceProviderSupport.payload(
                url: $0["url"],
                base64: $0["b64_json"],
                mimeType: $0["mime_type"] ?? $0["mimeType"]
            )
        }
        return try BoneImageInferenceProviderSupport.requirePayloads(payloads)
    }
}
