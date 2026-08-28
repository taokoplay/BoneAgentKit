import Foundation

/// 聚合 Anthropic Messages 完整响应和 SSE 事件，不保留原始载荷。
public enum BoneAnthropicResponseAggregator {
    /// 命中表示输出预算耗尽的 stop_reason 集合；只拦截明确截断，未知原因保持宽容。
    static let truncationStopReasons: Set<String> = ["max_tokens", "max_output_tokens"]

    public static func nonStreamingText(from json: [String: Any]) throws -> String {
        if let reason = json["stop_reason"] as? String,
           truncationStopReasons.contains(reason) {
            throw BoneInferenceTransportError.outputTruncated
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let value = block["text"] as? String,
                  !value.isEmpty else { return nil }
            return value
        }.joined(separator: "\n")
        guard !text.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return text
    }

    public static func streamingText(
        from events: [BoneInferenceEventStreamEvent]
    ) throws -> String {
        var text = ""
        var completed = false
        for event in events {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  let type = json["type"] as? String,
                  event.event != "error",
                  type != "error"
            else { throw BoneInferenceTransportError.invalidResponse }
            if type == "message_stop" {
                guard !completed else { throw BoneInferenceTransportError.invalidResponse }
                completed = true
                continue
            }
            guard !completed else { throw BoneInferenceTransportError.invalidResponse }
            if type == "ping" { continue }
            if type == "message_delta",
               let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String,
               truncationStopReasons.contains(reason) {
                throw BoneInferenceTransportError.outputTruncated
            }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let value = delta["text"] as? String {
                text += value
            }
        }
        guard completed, !text.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return text
    }
}
