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
        if requiringSingleCompletedChoice {
            guard choices.count == 1,
                  (choice["index"] == nil || choice["index"] as? Int == 0),
                  choice["finish_reason"] as? String == "stop" else {
                if choice["finish_reason"] as? String == "length" {
                    throw BoneInferenceTransportError.outputTruncated
                }
                throw BoneInferenceTransportError.invalidResponse
            }
        } else if choice["finish_reason"] as? String == "length" {
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
            let choices = json["choices"] as? [[String: Any]] ?? []
            if requiringSingleCompletedChoice, choices.count > 1 {
                throw BoneInferenceTransportError.invalidResponse
            }
            for choice in choices {
                if requiringSingleCompletedChoice,
                   let index = choice["index"] as? Int,
                   index != 0 {
                    throw BoneInferenceTransportError.invalidResponse
                }
                if let finishReason = choice["finish_reason"] as? String {
                    if finishReason == "length" {
                        throw BoneInferenceTransportError.outputTruncated
                    }
                    if requiringSingleCompletedChoice {
                        guard finishReason == "stop", !sawStop else {
                            throw BoneInferenceTransportError.invalidResponse
                        }
                        sawStop = true
                    }
                }
                let delta = choice["delta"] as? [String: Any]
                if let content = delta?["content"] as? String {
                    text += content
                }
            }
        }
        guard completed, !text.isEmpty,
              !requiringSingleCompletedChoice || sawStop else {
            throw BoneInferenceTransportError.invalidResponse
        }
        return text
    }
}
