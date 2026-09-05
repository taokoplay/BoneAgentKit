import Foundation

/// 聚合 OpenAI-compatible 完整响应和 SSE 事件，不保留原始载荷。
public enum BoneOpenAIResponseAggregator {
    public static func nonStreamingText(
        from json: [String: Any],
        requiringSingleCompletedChoice: Bool = false
    ) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw BoneInferenceTransportError.invalidResponse
        }
        // Text APIs return one answer, never silently select or concatenate choices.
        // Keep the legacy flag source-compatible; ordinary text now has the same contract.
        guard json["error"] == nil, choices.count == 1,
              choice["index"] == nil || choice["index"] as? Int == 0 else {
            throw BoneInferenceTransportError.invalidResponse
        }
        try validateFinishReason(choice["finish_reason"] as? String)
        guard message["refusal"] == nil || message["refusal"] is NSNull else {
            throw BoneInferenceTransportError.invalidResponse
        }
        if let content = message["content"] as? String, !content.isEmpty {
            return content
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text",
                      let value = part["text"] as? String,
                      !value.isEmpty else { return nil }
                return value
            }.joined()
            if !text.isEmpty { return text }
        }
        throw BoneInferenceTransportError.invalidResponse
    }

    public static func streamingText(
        from events: [BoneInferenceEventStreamEvent],
        requiringSingleCompletedChoice: Bool = false
    ) throws -> String {
        var text = ""
        var completed = false
        var sawStop = false
        for event in events {
            if event.data == "[DONE]" {
                guard !completed else { throw BoneInferenceTransportError.invalidResponse }
                completed = true
                continue
            }
            guard !completed else { throw BoneInferenceTransportError.invalidResponse }
            guard event.event != "error",
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  json["error"] == nil
            else {
                throw BoneInferenceTransportError.invalidResponse
            }
            guard let choices = json["choices"] as? [[String: Any]], choices.count <= 1 else {
                throw BoneInferenceTransportError.invalidResponse
            }
            for choice in choices {
                guard !sawStop,
                      choice["index"] == nil || choice["index"] as? Int == 0 else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                if let reason = choice["finish_reason"], !(reason is NSNull) {
                    try validateFinishReason(reason as? String)
                    sawStop = true
                }
                let delta = choice["delta"] as? [String: Any]
                guard delta?["refusal"] == nil || delta?["refusal"] is NSNull else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                if let content = delta?["content"] as? String {
                    text += content
                }
            }
        }
        guard completed, !text.isEmpty, sawStop else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return text
    }

    private static func validateFinishReason(_ reason: String?) throws {
        if reason == "length" { throw BoneInferenceTransportError.outputTruncated }
        guard reason == "stop" else { throw BoneInferenceTransportError.invalidResponse }
    }
}
