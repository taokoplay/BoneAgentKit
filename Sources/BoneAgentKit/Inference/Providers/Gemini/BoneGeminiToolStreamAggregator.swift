import Foundation

/// Gemini streamGenerateContent SSE 聚合器；每个事件必须是完整 JSON response chunk。
enum BoneGeminiToolStreamAggregator {
    static let maximumEventBytes = 4 * 1_048_576

    static func aggregate(
        events: [BoneInferenceEventStreamEvent],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        guard !events.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        var totalBytes = 0
        var parts: [[String: Any]] = []
        var terminalReason: String?
        var usage: [String: Any]?

        for event in events {
            guard event.event != "error" else { throw BoneInferenceTransportError.invalidResponse }
            let bytes = event.data.lengthOfBytes(using: .utf8)
            let (next, overflow) = totalBytes.addingReportingOverflow(bytes)
            guard !overflow, next <= maximumEventBytes,
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any], json["error"] == nil,
                  let candidates = json["candidates"] as? [[String: Any]], candidates.count == 1,
                  let candidate = candidates.first else {
                throw BoneInferenceTransportError.invalidResponse
            }
            totalBytes = next
            if terminalReason != nil { throw BoneInferenceTransportError.invalidResponse }
            if let content = candidate["content"] as? [String: Any],
               let chunkParts = content["parts"] as? [[String: Any]] {
                for part in chunkParts {
                    guard let fragment = part["text"] as? String else {
                        parts.append(part)
                        continue
                    }
                    let isThought = part["thought"] as? Bool == true
                    if let last = parts.last,
                       last["thought"] as? Bool == (isThought ? true : nil),
                       let existing = last["text"] as? String,
                       last["thoughtSignature"] == nil,
                       part["thoughtSignature"] == nil {
                        var merged = last
                        merged["text"] = existing + fragment
                        parts[parts.count - 1] = merged
                    } else {
                        parts.append(part)
                    }
                }
            }
            if let reason = candidate["finishReason"] as? String {
                terminalReason = reason
            }
            if let value = json["usageMetadata"] as? [String: Any] { usage = value }
        }
        guard let terminalReason else { throw BoneInferenceTransportError.invalidResponse }
        let synthetic: [String: Any] = [
            "candidates": [["finishReason": terminalReason, "content": ["role": "model", "parts": parts]]],
            "usageMetadata": usage ?? [:],
        ]
        return try BoneGeminiToolWire.parseResponse(synthetic, definitions: definitions)
    }
}
