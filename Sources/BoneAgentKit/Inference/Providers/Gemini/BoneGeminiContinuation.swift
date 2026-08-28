import Foundation

/// Gemini 原始 model parts 的 opaque envelope；仅用于同 Provider 下一轮重放。
enum BoneGeminiContinuation {
    static func make(parts: [[String: Any]]) throws -> BoneInferenceProviderContinuation? {
        guard parts.contains(where: { $0["thoughtSignature"] != nil }) else { return nil }
        guard JSONSerialization.isValidJSONObject(parts) else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let data = try JSONSerialization.data(withJSONObject: ["modelParts": parts], options: [.sortedKeys])
        do { return try .init(provider: .google, data: data) }
        catch { throw BoneInferenceTransportError.invalidResponse }
    }

    static func modelParts(from continuation: BoneInferenceProviderContinuation?) throws -> [[String: Any]]? {
        guard let continuation else { return nil }
        try continuation.validate(for: .google)
        guard let object = try? JSONSerialization.jsonObject(with: continuation.data) as? [String: Any],
              let parts = object["modelParts"] as? [[String: Any]],
              !parts.isEmpty else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        return parts
    }
}
