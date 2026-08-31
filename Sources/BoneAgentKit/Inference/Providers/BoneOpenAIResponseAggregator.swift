import Foundation

/// 聚合 OpenAI-compatible 完整响应和 SSE 事件，不保留原始载荷。
public enum BoneOpenAIResponseAggregator {
    public static func nonStreamingText(from json: [String: Any]) throws -> String {
        guard let choices = json["choices"] as? [[String: Any]],
              let choice = choices.first,
              let message = choice["message"] as? [String: Any]
        else {
            throw BoneInferenceTransportError.invalidResponse
        }
        if choice["finish_reason"] as? String == "length" {
            throw BoneInferenceTransportError.outputTruncated
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
        from events: [BoneInferenceEventStreamEvent]
    ) throws -> String {
        var text = ""
        var completed = false
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
            let choices = json["choices"] as? [[String: Any]] ?? []
            for choice in choices {
                if choice["finish_reason"] as? String == "length" {
                    throw BoneInferenceTransportError.outputTruncated
                }
                let delta = choice["delta"] as? [String: Any]
                if let content = delta?["content"] as? String {
                    text += content
                }
            }
        }
        guard completed, !text.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return text
    }
}
