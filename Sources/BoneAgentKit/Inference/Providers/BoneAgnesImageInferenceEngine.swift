import Foundation

/// Agnes 官方档位/比例图片协议。
public struct BoneAgnesImageInferenceEngine: BoneInferenceImageGenerating {
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
        guard request.count.value == 1,
              let size = request.size.requestSizeValue, !size.isEmpty,
              let ratio = request.size.requestRatioValue, !ratio.isEmpty else {
            throw BoneImageInferenceProviderError.unsupportedRequest
        }
        let httpRequest = try BoneImageInferenceProviderSupport.makeRequest(
            configuration: configuration,
            path: configuration.endpointOverrides["image"] ?? "/images/generations",
            authentication: .bearer,
            body: [
                "model": request.modelID,
                "prompt": request.prompt,
                "size": size,
                "ratio": ratio,
                "extra_body": ["response_format": "url"],
            ]
        )
        let json = try BoneImageInferenceProviderSupport.validatedJSON(
            try await transport.send(httpRequest)
        )
        let entries = json["data"] as? [[String: Any]] ?? []
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
