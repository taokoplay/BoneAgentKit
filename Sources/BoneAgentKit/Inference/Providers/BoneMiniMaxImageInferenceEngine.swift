import Foundation

/// MiniMax 原生 image_generation 图片协议。
public struct BoneMiniMaxImageInferenceEngine: BoneInferenceImageGenerating {
    private let configuration: BoneInferenceProviderConfiguration
    private let transport: any BoneInferenceHTTPTransport

    public init(
        configuration: BoneInferenceProviderConfiguration,
        transport: any BoneInferenceHTTPTransport = BoneInferenceURLSessionTransport()
    ) {
        self.configuration = configuration
        self.transport = transport
    }

    public func generateImages(
        request: BoneInferenceImageGenerationRequest
    ) async throws -> BoneInferenceImageGenerationResponse {
        let httpRequest = try BoneImageInferenceProviderSupport.makeRequest(
            configuration: configuration,
            path: configuration.endpointOverrides["image"] ?? "/v1/image_generation",
            authentication: .bearer,
            body: [
                "model": request.modelID,
                "prompt": request.prompt,
                "n": request.count.value,
                "width": request.size.width,
                "height": request.size.height,
                "response_format": "url",
            ]
        )
        let json = try BoneImageInferenceProviderSupport.validatedJSON(
            try await transport.send(httpRequest)
        )
        if let base = json["base_resp"] as? [String: Any],
           let code = base["status_code"] as? Int, code != 0 {
            throw BoneImageInferenceProviderError.invalidResponse
        }
        let data = json["data"] as? [String: Any] ?? [:]
        var payloads = try (data["image_urls"] as? [String] ?? []).compactMap {
            try BoneImageInferenceProviderSupport.payload(url: $0, base64: nil)
        }
        payloads.append(contentsOf: try (data["image_base64"] as? [String] ?? []).compactMap {
            try BoneImageInferenceProviderSupport.payload(url: nil, base64: $0)
        })
        return try BoneImageInferenceProviderSupport.requirePayloads(payloads)
    }
}
