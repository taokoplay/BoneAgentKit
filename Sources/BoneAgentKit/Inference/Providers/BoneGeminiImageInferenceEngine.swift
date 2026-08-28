import Foundation

/// Google Gemini generateContent 与 Imagen predict 图片协议。
public struct BoneGeminiImageInferenceEngine: BoneInferenceImageGenerating {
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
        let modelID = request.modelID.hasPrefix("models/")
            ? String(request.modelID.dropFirst("models/".count))
            : request.modelID
        if modelID.lowercased().hasPrefix("imagen-") {
            return try await generateImagen(request: request, modelID: modelID)
        }
        let template = configuration.endpointOverrides["geminiImage"]
            ?? "/v1beta/models/{model}:generateContent"
        let httpRequest = try BoneImageInferenceProviderSupport.makeRequest(
            configuration: configuration,
            path: template.replacingOccurrences(of: "{model}", with: modelID),
            authentication: .googleAPIKey,
            body: [
                "contents": [["role": "user", "parts": [["text": request.prompt]]]],
                "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
            ]
        )
        let json = try BoneImageInferenceProviderSupport.validatedJSON(
            try await transport.send(httpRequest)
        )
        try Self.rejectSafetyBlock(json)
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        let payloads = try candidates.flatMap { candidate -> [BoneInferenceImagePayload] in
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { return [] }
            return try parts.compactMap { part in
                guard let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any] else {
                    return nil
                }
                return try BoneImageInferenceProviderSupport.payload(
                    url: nil,
                    base64: inline["data"],
                    mimeType: inline["mimeType"] ?? inline["mime_type"]
                )
            }
        }
        return try BoneImageInferenceProviderSupport.requirePayloads(payloads)
    }

    private func generateImagen(
        request: BoneInferenceImageGenerationRequest,
        modelID: String
    ) async throws -> BoneInferenceImageGenerationResponse {
        let template = configuration.endpointOverrides["imagenImage"]
            ?? configuration.endpointOverrides["image"]
            ?? "/v1beta/models/{model}:predict"
        let httpRequest = try BoneImageInferenceProviderSupport.makeRequest(
            configuration: configuration,
            path: template.replacingOccurrences(of: "{model}", with: modelID),
            authentication: .googleAPIKey,
            body: [
                "instances": [["prompt": request.prompt]],
                "parameters": [
                    "sampleCount": request.count.value,
                    "aspectRatio": request.size.requestRatioValue ?? request.size.aspectRatio,
                ],
            ]
        )
        let json = try BoneImageInferenceProviderSupport.validatedJSON(
            try await transport.send(httpRequest)
        )
        let predictions = json["predictions"] as? [[String: Any]] ?? []
        let payloads = try predictions.compactMap {
            try BoneImageInferenceProviderSupport.payload(
                url: $0["url"],
                base64: $0["bytesBase64Encoded"] ?? $0["b64_json"],
                mimeType: $0["mimeType"] ?? $0["mime_type"]
            )
        }
        return try BoneImageInferenceProviderSupport.requirePayloads(payloads)
    }

    private static func rejectSafetyBlock(_ json: [String: Any]) throws {
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String, !reason.isEmpty {
            throw BoneInferenceTransportError.safetyBlocked
        }
        let candidates = json["candidates"] as? [[String: Any]] ?? []
        if candidates.contains(where: { ($0["finishReason"] as? String)?.uppercased() == "SAFETY" }) {
            throw BoneInferenceTransportError.safetyBlocked
        }
    }
}
