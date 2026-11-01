import Foundation

/// 聚合 Anthropic Messages 完整响应和 SSE 事件，不保留原始载荷。
public enum BoneAnthropicResponseAggregator {
    public struct TextResult: Equatable, Sendable {
        public let text: String
        public let finishReason: BoneInferenceFinishReason

        public init(text: String, finishReason: BoneInferenceFinishReason) {
            self.text = text
            self.finishReason = finishReason
        }
    }

    public static func nonStreamingResult(from json: [String: Any]) throws -> TextResult {
        guard let reason = json["stop_reason"] as? String else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let finishReason: BoneInferenceFinishReason
        switch reason {
        case "max_tokens", "max_output_tokens": finishReason = .length
        case "end_turn", "stop_sequence": finishReason = .stop
        default: throw BoneInferenceTransportError.invalidResponse
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.compactMap { block -> String? in
            guard block["type"] as? String == "text",
                  let value = block["text"] as? String,
                  !value.isEmpty else { return nil }
            return value
        }.joined(separator: "\n")
        guard !text.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return .init(text: text, finishReason: finishReason)
    }

    public static func streamingResult(
        from events: [BoneInferenceEventStreamEvent]
    ) throws -> TextResult {
        var text = ""
        var completed = false
        var finishReason: BoneInferenceFinishReason?
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
               let reason = delta["stop_reason"] as? String {
                switch reason {
                case "max_tokens", "max_output_tokens": finishReason = .length
                case "end_turn", "stop_sequence": finishReason = .stop
                default: throw BoneInferenceTransportError.invalidResponse
                }
            }
            if type == "content_block_delta",
               let delta = json["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let value = delta["text"] as? String {
                text += value
            }
        }
        guard completed, !text.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        return .init(text: text, finishReason: finishReason ?? .stop)
    }

    public static func nonStreamingText(from json: [String: Any]) throws -> String {
        try nonStreamingResult(from: json).text
    }

    public static func streamingText(
        from events: [BoneInferenceEventStreamEvent]
    ) throws -> String {
        try streamingResult(from: events).text
    }
}
