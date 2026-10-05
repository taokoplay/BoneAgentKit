import Foundation

/// Usage is cumulative within a provider response, not the sum of stream chunks.
enum BoneProviderUsage {
    enum Wire { case openAI, anthropic, gemini }

    static func read(_ json: [String: Any], wire: Wire) throws -> BoneInferenceUsage? {
        let key = wire == .gemini ? "usageMetadata" : "usage"
        guard let raw = json[key], !(raw is NSNull) else { return nil }
        guard let object = raw as? [String: Any] else { throw BoneInferenceTransportError.invalidResponse }
        switch wire {
        case .openAI: return try BoneOpenAIToolWire.usage(object)
        case .anthropic: return try BoneAnthropicToolWire.usage(object)
        case .gemini: return try BoneGeminiToolWire.parseUsage(object)
        }
    }

    static func read(_ events: [BoneInferenceEventStreamEvent], wire: Wire) throws -> BoneInferenceUsage? {
        var latest: BoneInferenceUsage?
        var anthropic: [String: Any] = [:]
        for event in events where event.data != "[DONE]" {
            guard let json = try JSONSerialization.jsonObject(with: Data(event.data.utf8)) as? [String: Any] else {
                throw BoneInferenceTransportError.invalidResponse
            }
            if wire == .anthropic {
                let object = (json["type"] as? String) == "message_start" ? (json["message"] as? [String: Any]) : json
                if let raw = object?["usage"], !(raw is NSNull) {
                    guard let value = raw as? [String: Any] else { throw BoneInferenceTransportError.invalidResponse }
                    anthropic.merge(value) { _, new in new }
                }
            } else if let usage = try read(json, wire: wire) { latest = usage }
        }
        if wire == .anthropic {
            guard anthropic["input_tokens"] != nil, anthropic["output_tokens"] != nil else { return nil }
            return try BoneAnthropicToolWire.usage(anthropic)
        }
        return latest
    }
}
