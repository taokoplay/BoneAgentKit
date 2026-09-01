import Foundation

struct BoneGeminiNormalizedEventMapper {
    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var reasoningActive = false
    private var localCallIndex = 0

    init(disclosure: BoneInferenceReasoningDisclosure, definitions: [BoneAgentToolDefinition]) {
        self.disclosure = disclosure
        toolIDsByWireName = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard let name = definition.wireName else { return nil }
            return (name, definition.id)
        })
    }

    mutating func consume(_ event: BoneInferenceEventStreamEvent) throws -> [BoneInferenceStreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any], json["error"] == nil,
              let candidates = json["candidates"] as? [[String: Any]], candidates.count == 1,
              let candidate = candidates.first else { throw BoneInferenceTransportError.invalidResponse }
        var result: [BoneInferenceStreamEvent] = []
        if let content = candidate["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            for part in parts {
                if part["thought"] as? Bool == true {
                    if disclosure == .providerReadable,
                       let text = part["text"] as? String, !text.isEmpty {
                        if !reasoningActive {
                            result.append(.reasoningStarted(kind: .providerReadable))
                            reasoningActive = true
                        }
                        result.append(.reasoningDelta(text))
                    }
                    continue
                }
                if reasoningActive { result.append(.reasoningCompleted); reasoningActive = false }
                if let text = part["text"] as? String, !text.isEmpty { result.append(.textDelta(text)) }
                if let function = part["functionCall"] as? [String: Any],
                   let name = function["name"] as? String,
                   let toolID = toolIDsByWireName[name],
                   let args = function["args"] as? [String: Any] {
                    let id = function["id"] as? String ?? "gemini-local-\(localCallIndex)"
                    localCallIndex += 1
                    result.append(.toolCallStarted(id: id, toolID: toolID))
                    result.append(.toolArgumentsDelta(
                        id: id,
                        data: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                    ))
                    result.append(.toolCallCompleted(id: id))
                }
            }
        }
        if candidate["finishReason"] != nil, reasoningActive {
            result.append(.reasoningCompleted)
            reasoningActive = false
        }
        if let raw = json["usageMetadata"] as? [String: Any],
           let input = raw["promptTokenCount"] as? Int,
           let output = raw["candidatesTokenCount"] as? Int {
            result.append(.usage(try BoneInferenceUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: raw["cachedContentTokenCount"] as? Int,
                reasoningTokens: raw["thoughtsTokenCount"] as? Int
            ).validated()))
        }
        return result
    }
}
