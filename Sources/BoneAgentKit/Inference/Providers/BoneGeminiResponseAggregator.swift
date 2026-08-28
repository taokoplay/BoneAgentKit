import Foundation

/// 聚合 Gemini GenerateContent 响应，并优先识别结构化安全阻断。
public enum BoneGeminiResponseAggregator {
    public static func text(from json: [String: Any]) throws -> String {
        if let feedback = json["promptFeedback"] as? [String: Any],
           let reason = feedback["blockReason"] as? String,
           !reason.isEmpty {
            throw BoneInferenceTransportError.safetyBlocked
        }
        guard let candidates = json["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            throw BoneInferenceTransportError.invalidResponse
        }
        if let reason = candidate["finishReason"] as? String,
           ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"].contains(reason.uppercased()) {
            throw BoneInferenceTransportError.safetyBlocked
        }
        guard let content = candidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let text = parts.compactMap { part -> String? in
            guard let value = part["text"] as? String, !value.isEmpty else { return nil }
            return value
        }.joined()
        guard !text.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return text
    }
}
