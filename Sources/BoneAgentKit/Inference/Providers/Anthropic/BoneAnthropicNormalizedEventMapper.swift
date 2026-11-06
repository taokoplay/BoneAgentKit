import Foundation

/// Anthropic Messages SSE 到供应商无关增量事件的严格映射。
struct BoneAnthropicNormalizedEventMapper {
    private enum BlockKind { case reasoning, text, tool(id: String, toolID: String) }

    private let disclosure: BoneInferenceReasoningDisclosure
    private let toolIDsByWireName: [String: String]
    private var blocks: [Int: BlockKind] = [:]
    private(set) var activities: [BoneInferenceActivity] = []
    private var lastActivity: BoneInferenceActivity?
    private(set) var hasOutputToken = false
    private var usageCounters: [String: Int] = [:]
    private var lastUsage: BoneInferenceUsage?

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
        activities.removeAll(keepingCapacity: true)
        guard let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
              let json = object as? [String: Any],
              let type = json["type"] as? String,
              event.event != "error", type != "error" else {
            throw BoneInferenceTransportError.invalidResponse
        }
        switch type {
        case "ping":
            return []
        case "message_start":
            return try mergedUsage((json["message"] as? [String: Any])?["usage"])
        case "message_delta":
            if let delta = json["delta"] as? [String: Any],
               let reason = delta["stop_reason"] as? String, !reason.isEmpty {
                recordActivity(.validatingResponse)
            }
            return try mergedUsage(json["usage"])
        case "message_stop":
            recordActivity(.validatingResponse)
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
                recordActivity(.reasoning)
                if blockType == "thinking", let text = raw["thinking"] as? String, !text.isEmpty {
                    hasOutputToken = true
                }
                return blockType == "thinking" && disclosure == .providerReadable
                    ? [.reasoningStarted(kind: .providerReadable)] : []
            case "text":
                blocks[index] = .text
                recordActivity(.generatingResponse)
                if let text = raw["text"] as? String, !text.isEmpty { hasOutputToken = true }
                return []
            case "tool_use":
                guard let id = raw["id"] as? String,
                      let name = raw["name"] as? String,
                      let toolID = toolIDsByWireName[name] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                blocks[index] = .tool(id: id, toolID: toolID)
                recordActivity(.generatingToolCall)
                if let input = raw["input"] as? [String: Any], !input.isEmpty { hasOutputToken = true }
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
                if !text.isEmpty { hasOutputToken = true }
                recordActivity(.reasoning)
                return disclosure == .providerReadable ? [.reasoningDelta(text)] : []
            case (.reasoning, "signature_delta"):
                return []
            case (.text, "text_delta"):
                guard let text = delta["text"] as? String else { throw BoneInferenceTransportError.invalidResponse }
                if !text.isEmpty { hasOutputToken = true }
                recordActivity(.generatingResponse)
                return [.textDelta(text)]
            case let (.tool(id, _), "input_json_delta"):
                guard let value = delta["partial_json"] as? String else { throw BoneInferenceTransportError.invalidResponse }
                if !value.isEmpty { hasOutputToken = true }
                recordActivity(.generatingToolCall)
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

    private mutating func mergedUsage(_ raw: Any?) throws -> [BoneInferenceStreamEvent] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let values = raw as? [String: Any] else { throw BoneInferenceTransportError.invalidResponse }
        // Keep only the four counters understood by the final wire parser. A partial
        // snapshot cannot become BoneInferenceUsage until both required counts are known.
        for key in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] {
            guard let value = values[key], !(value is NSNull) else { continue }
            guard let count = value as? Int, count >= 0 else { throw BoneInferenceTransportError.invalidResponse }
            usageCounters[key] = count
        }
        guard usageCounters["input_tokens"] != nil, usageCounters["output_tokens"] != nil,
              let usage = try BoneAnthropicToolWire.usage(usageCounters), usage != lastUsage else { return [] }
        lastUsage = usage
        return [.usage(usage)]
    }

    mutating func finish() {
        activities.removeAll(keepingCapacity: true)
        recordActivity(.validatingResponse)
    }

    private mutating func recordActivity(_ activity: BoneInferenceActivity) {
        guard lastActivity != activity else { return }
        lastActivity = activity
        activities.append(activity)
    }
}
