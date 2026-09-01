import Foundation

/// Anthropic Messages SSE 到供应商无关增量事件的严格映射。
struct BoneAnthropicNormalizedEventMapper {
    private enum BlockKind { case reasoning, text, tool(id: String, toolID: String) }

    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var blocks: [Int: BlockKind] = [:]

    init(
        disclosure: BoneInferenceReasoningDisclosure,
        definitions: [BoneAgentToolDefinition] = []
    ) {
        self.disclosure = disclosure
        toolIDsByWireName = Dictionary(uniqueKeysWithValues: definitions.compactMap { definition in
            guard let name = definition.wireName else { return nil }
            return (name, definition.id)
        })
    }

    mutating func consume(_ event: BoneInferenceEventStreamEvent) throws -> [BoneInferenceStreamEvent] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any],
              let type = json["type"] as? String,
              event.event != "error", type != "error" else {
            throw BoneInferenceTransportError.invalidResponse
        }
        switch type {
        case "ping", "message_start", "message_delta", "message_stop":
            return []
        case "content_block_start":
            guard let index = json["index"] as? Int,
                  blocks[index] == nil,
                  let raw = json["content_block"] as? [String: Any],
                  let blockType = raw["type"] as? String else {
                throw BoneInferenceTransportError.invalidResponse
            }
            switch blockType {
            case "thinking", "redacted_thinking":
                blocks[index] = .reasoning
                return blockType == "thinking" && disclosure == .providerReadable
                    ? [.reasoningStarted(kind: .providerReadable)] : []
            case "text":
                blocks[index] = .text
                return []
            case "tool_use":
                guard let id = raw["id"] as? String,
                      let name = raw["name"] as? String,
                      let toolID = toolIDsByWireName[name] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                blocks[index] = .tool(id: id, toolID: toolID)
                return [.toolCallStarted(id: id, toolID: toolID)]
            default:
                throw BoneInferenceTransportError.invalidResponse
            }
        case "content_block_delta":
            guard let index = json["index"] as? Int,
                  let block = blocks[index],
                  let delta = json["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else {
                throw BoneInferenceTransportError.invalidResponse
            }
            switch (block, deltaType) {
            case (.reasoning, "thinking_delta"):
                guard let text = delta["thinking"] as? String else { throw BoneInferenceTransportError.invalidResponse }
                return disclosure == .providerReadable ? [.reasoningDelta(text)] : []
            case (.reasoning, "signature_delta"):
                return []
            case (.text, "text_delta"):
                guard let text = delta["text"] as? String else { throw BoneInferenceTransportError.invalidResponse }
                return [.textDelta(text)]
            case let (.tool(id, _), "input_json_delta"):
                guard let value = delta["partial_json"] as? String else { throw BoneInferenceTransportError.invalidResponse }
                return [.toolArgumentsDelta(id: id, data: Data(value.utf8))]
            default:
                throw BoneInferenceTransportError.invalidResponse
            }
        case "content_block_stop":
            guard let index = json["index"] as? Int,
                  let block = blocks.removeValue(forKey: index) else {
                throw BoneInferenceTransportError.invalidResponse
            }
            switch block {
            case .reasoning:
                return disclosure == .providerReadable ? [.reasoningCompleted] : []
            case .text:
                return []
            case let .tool(id, _):
                return [.toolCallCompleted(id: id)]
            }
        default:
            throw BoneInferenceTransportError.invalidResponse
        }
    }
}
