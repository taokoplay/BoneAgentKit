import Foundation

/// Anthropic Tool SSE 的严格 content-block 状态机。
enum BoneAnthropicToolStreamAggregator {
    static func aggregate(
        events: [BoneInferenceEventStreamEvent],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let definitions = try definitions.map { try $0.validatedForModelExposure() }
        let stableIDs = Dictionary(uniqueKeysWithValues: definitions.map { ($0.wireName!, $0.id) })
        guard stableIDs.count == definitions.count else { throw BoneInferenceTransportError.invalidResponse }

        var blocks: [Int: Block] = [:]
        var stopReason: String?
        var inputTokens: Int?
        var outputTokens: Int?
        var stopped = false

        for event in events {
            guard !stopped,
                  let object = try? JSONSerialization.jsonObject(with: Data(event.data.utf8)),
                  let json = object as? [String: Any],
                  let type = json["type"] as? String,
                  event.event != "error", type != "error" else {
                throw BoneInferenceTransportError.invalidResponse
            }
            switch type {
            case "ping":
                continue
            case "message_start":
                if let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] {
                    inputTokens = usage["input_tokens"] as? Int
                    outputTokens = usage["output_tokens"] as? Int
                }
            case "content_block_start":
                guard let index = json["index"] as? Int, index >= 0,
                      blocks[index] == nil,
                      let raw = json["content_block"] as? [String: Any],
                      let blockType = raw["type"] as? String else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                if blockType == "text" {
                    blocks[index] = .text(value: raw["text"] as? String ?? "", stopped: false)
                } else if blockType == "tool_use",
                          let id = raw["id"] as? String,
                          let name = raw["name"] as? String,
                          stableIDs[name] != nil {
                    blocks[index] = .tool(id: id, name: name, arguments: "", stopped: false)
                } else if blockType == "thinking" || blockType == "redacted_thinking" {
                    // 推理内容不是业务输出，不保存、不续传、不计入 Assistant Turn。
                    blocks[index] = .reasoning(stopped: false)
                } else {
                    throw BoneInferenceTransportError.invalidResponse
                }
            case "content_block_delta":
                guard let index = json["index"] as? Int,
                      let delta = json["delta"] as? [String: Any],
                      let block = blocks[index] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                switch (block, delta["type"] as? String) {
                case let (.text(value, false), "text_delta"):
                    guard let fragment = delta["text"] as? String else {
                        throw BoneInferenceTransportError.invalidResponse
                    }
                    blocks[index] = .text(value: value + fragment, stopped: false)
                case let (.tool(id, name, arguments, false), "input_json_delta"):
                    guard let fragment = delta["partial_json"] as? String else {
                        throw BoneInferenceTransportError.invalidResponse
                    }
                    blocks[index] = .tool(id: id, name: name, arguments: arguments + fragment, stopped: false)
                case (.reasoning(false), "thinking_delta"),
                     (.reasoning(false), "signature_delta"):
                    // reasoning/signature 可能含敏感模型内部状态，仅验证顺序后丢弃。
                    break
                default:
                    throw BoneInferenceTransportError.invalidResponse
                }
            case "content_block_stop":
                guard let index = json["index"] as? Int, let block = blocks[index] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                switch block {
                case let .text(value, false): blocks[index] = .text(value: value, stopped: true)
                case let .tool(id, name, arguments, false): blocks[index] = .tool(id: id, name: name, arguments: arguments, stopped: true)
                case .reasoning(false): blocks[index] = .reasoning(stopped: true)
                default: throw BoneInferenceTransportError.invalidResponse
                }
            case "message_delta":
                guard stopReason == nil,
                      let delta = json["delta"] as? [String: Any],
                      let reason = delta["stop_reason"] as? String else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                stopReason = reason
                if let usage = json["usage"] as? [String: Any],
                   let output = usage["output_tokens"] as? Int {
                    outputTokens = output
                }
            case "message_stop":
                guard stopReason != nil else { throw BoneInferenceTransportError.invalidResponse }
                stopped = true
            default:
                throw BoneInferenceTransportError.invalidResponse
            }
        }

        guard stopped, let stopReason else {
            throw BoneInferenceTransportError.invalidResponse
        }
        if stopReason == "max_tokens" || stopReason == "max_output_tokens" {
            throw BoneInferenceTransportError.outputTruncated
        }
        guard !blocks.isEmpty,
              blocks.keys.sorted() == Array(0..<blocks.count),
              blocks.values.allSatisfy(\.isStopped) else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let deliverableBlocks = blocks.filter { !$0.value.isReasoning }
        guard !deliverableBlocks.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        let hasTools = deliverableBlocks.values.contains { $0.isTool }
        guard (hasTools && stopReason == "tool_use") || (!hasTools && stopReason == "end_turn") else {
            throw BoneInferenceTransportError.invalidResponse
        }

        var content: [BoneInferenceAssistantContent] = []
        var callIDs = Set<String>()
        for index in deliverableBlocks.keys.sorted() {
            switch deliverableBlocks[index]! {
            case let .text(value, true):
                guard !value.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
                content.append(.text(value))
            case let .tool(id, name, arguments, true):
                guard callIDs.insert(id).inserted, let stableID = stableIDs[name] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                let data = Data(arguments.utf8)
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                content.append(.toolCall(.init(id: id, toolID: stableID, arguments: data)))
            default:
                throw BoneInferenceTransportError.invalidResponse
            }
        }
        let turn: BoneInferenceAssistantTurn
        do { turn = try .init(content: content) }
        catch { throw BoneInferenceTransportError.invalidResponse }
        let usage: BoneInferenceUsage?
        if let inputTokens, let outputTokens {
            do {
                usage = try BoneInferenceUsage(
                    inputTokens: inputTokens,
                    outputTokens: outputTokens,
                    cachedInputTokens: nil,
                    reasoningTokens: nil
                ).validated()
            } catch {
                throw BoneInferenceTransportError.invalidResponse
            }
        } else {
            usage = nil
        }
        return .init(
            assistantTurn: turn,
            finishReason: hasTools ? .toolCalls : .stop,
            usage: usage,
            refusal: nil,
            providerContinuation: nil
        )
    }
}

private extension BoneAnthropicToolStreamAggregator {
    enum Block {
        case text(value: String, stopped: Bool)
        case tool(id: String, name: String, arguments: String, stopped: Bool)
        case reasoning(stopped: Bool)

        var isStopped: Bool {
            switch self {
            case let .text(_, stopped), let .tool(_, _, _, stopped), let .reasoning(stopped):
                return stopped
            }
        }
        var isTool: Bool {
            if case .tool = self { return true }
            return false
        }
        var isReasoning: Bool {
            if case .reasoning = self { return true }
            return false
        }
    }
}
