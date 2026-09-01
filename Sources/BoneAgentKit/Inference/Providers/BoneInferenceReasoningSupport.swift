import Foundation

/// 仅从各协议已知的可读字段提取推理；opaque signature 与未知对象永不字符串化。
enum BoneInferenceReasoningSupport {
    static func anthropic(
        json: [String: Any],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard disclosure == .providerReadable,
              let blocks = json["content"] as? [[String: Any]] else { return nil }
        return make(
            kind: .providerReadable,
            fragments: blocks.compactMap { block in
                guard block["type"] as? String == "thinking" else { return nil }
                return block["thinking"] as? String
            }
        )
    }

    static func anthropic(
        events: [BoneInferenceEventStreamEvent],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard disclosure == .providerReadable else { return nil }
        var fragments: [String] = []
        for event in events {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  json["type"] as? String == "content_block_delta",
                  let delta = json["delta"] as? [String: Any],
                  delta["type"] as? String == "thinking_delta",
                  let text = delta["thinking"] as? String else { continue }
            fragments.append(text)
        }
        return make(kind: .providerReadable, fragments: fragments)
    }

    static func openAI(
        json: [String: Any],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else { return nil }
        return openAI(message: message, disclosure: disclosure)
    }

    static func openAI(
        events: [BoneInferenceEventStreamEvent],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard disclosure != .hidden else { return nil }
        var readable: [String?] = []
        var summaries: [String?] = []
        for event in events {
            guard event.data != "[DONE]",
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any] else { continue }
            readable.append(delta["reasoning_content"] as? String)
            summaries.append(delta["reasoning_summary"] as? String)
        }
        if disclosure == .providerReadable,
           let result = make(kind: .providerReadable, fragments: readable) { return result }
        return make(kind: .summary, fragments: summaries)
    }

    static func openAI(
        message: [String: Any],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        switch disclosure {
        case .hidden:
            return nil
        case .summary:
            return make(kind: .summary, fragments: [message["reasoning_summary"] as? String])
        case .providerReadable:
            if let value = make(
                kind: .providerReadable,
                fragments: [message["reasoning_content"] as? String]
            ) { return value }
            return make(kind: .summary, fragments: [message["reasoning_summary"] as? String])
        }
    }

    static func gemini(
        json: [String: Any],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard let candidates = json["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        return gemini(parts: parts, disclosure: disclosure)
    }

    static func gemini(
        events: [BoneInferenceEventStreamEvent],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard disclosure == .providerReadable else { return nil }
        var parts: [[String: Any]] = []
        for event in events {
            guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let values = content["parts"] as? [[String: Any]] else { continue }
            parts.append(contentsOf: values)
        }
        return gemini(parts: parts, disclosure: disclosure)
    }

    static func gemini(
        parts: [[String: Any]],
        disclosure: BoneInferenceReasoningDisclosure
    ) -> BoneInferenceReasoning? {
        guard disclosure == .providerReadable else { return nil }
        return make(
            kind: .providerReadable,
            fragments: parts.compactMap { part in
                guard part["thought"] as? Bool == true else { return nil }
                return part["text"] as? String
            }
        )
    }

    private static func make(
        kind: BoneInferenceReasoning.Kind,
        fragments: [String?]
    ) -> BoneInferenceReasoning? {
        let text = fragments.compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined()
        return try? BoneInferenceReasoning(kind: kind, text: text)
    }
}
