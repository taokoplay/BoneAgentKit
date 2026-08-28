import Foundation

/// Anthropic Messages Tool wire 的内部映射。
enum BoneAnthropicToolWire {
    static func definitions(_ values: [BoneAgentToolDefinition]) throws -> [[String: Any]] {
        try validated(values).map { definition in
            [
                "name": definition.wireName!,
                "description": definition.summary,
                "input_schema": try schema(definition.inputSchema!),
            ]
        }
    }

    static func messages(
        _ values: [BoneInferenceMessage],
        definitions: [BoneAgentToolDefinition]
    ) throws -> [[String: Any]] {
        let definitions = try validated(definitions)
        let wireNames = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.wireName!) })
        var knownCalls: [String: String] = [:]
        var result: [[String: Any]] = []

        for message in values {
            if let text = message.content {
                guard message.role == .user || message.role == .assistant,
                      message.assistantTurn == nil,
                      message.toolResult == nil,
                      message.toolResults == nil else {
                    throw BoneInferenceError.invalidMessage
                }
                result.append(["role": message.role.rawValue, "content": text])
                continue
            }
            if let turn = message.assistantTurn {
                guard message.role == .assistant,
                      turn.structuredOutputs.isEmpty else {
                    throw BoneInferenceError.invalidMessage
                }
                var blocks: [[String: Any]] = []
                for block in turn.content {
                    switch block {
                    case let .text(text):
                        blocks.append(["type": "text", "text": text])
                    case .structured:
                        throw BoneInferenceError.invalidMessage
                    case let .toolCall(call):
                        guard let name = wireNames[call.toolID], knownCalls[call.id] == nil,
                              let input = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
                            throw BoneInferenceError.invalidMessage
                        }
                        knownCalls[call.id] = call.toolID
                        blocks.append(["type": "tool_use", "id": call.id, "name": name, "input": input])
                    }
                }
                guard !blocks.isEmpty else { throw BoneInferenceError.invalidMessage }
                result.append(["role": "assistant", "content": blocks])
                continue
            }
            if message.toolResult != nil || message.toolResults != nil {
                guard message.role == .tool else { throw BoneInferenceError.invalidMessage }
                let batch = try message.requiredToolResults()
                let blocks = try batch.results.map { value -> [String: Any] in
                    guard knownCalls[value.callID] == value.toolID,
                          wireNames[value.toolID] != nil else {
                        throw BoneInferenceError.invalidToolResult
                    }
                    return [
                        "type": "tool_result",
                        "tool_use_id": value.callID,
                        "content": try contentString(value.content),
                        "is_error": value.isError,
                    ]
                }
                result.append(["role": "user", "content": blocks])
                continue
            }
            throw BoneInferenceError.invalidMessage
        }
        return result
    }

    static func parseResponse(
        _ json: [String: Any],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let definitions = try validated(definitions)
        let stableIDs = Dictionary(uniqueKeysWithValues: definitions.map { ($0.wireName!, $0.id) })
        guard let blocks = json["content"] as? [[String: Any]], !blocks.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        var content: [BoneInferenceAssistantContent] = []
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard let text = block["text"] as? String, !text.isEmpty else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                content.append(.text(text))
            case "tool_use":
                guard let id = block["id"] as? String,
                      let name = block["name"] as? String,
                      let stableID = stableIDs[name],
                      let input = block["input"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(input) else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
                content.append(.toolCall(.init(id: id, toolID: stableID, arguments: data)))
            default:
                throw BoneInferenceTransportError.invalidResponse
            }
        }
        let turn: BoneInferenceAssistantTurn
        do { turn = try .init(content: content) }
        catch { throw BoneInferenceTransportError.invalidResponse }
        let reason = finishReason(json["stop_reason"] as? String, hasCalls: !turn.toolCalls.isEmpty)
        let usage = try usage(json["usage"] as? [String: Any])
        return .init(
            assistantTurn: turn,
            finishReason: reason,
            usage: usage,
            refusal: nil,
            providerContinuation: nil
        )
    }

    static func schema(_ value: BoneToolSchema) throws -> [String: Any] {
        switch value {
        case let .object(properties, required, additionalProperties):
            return ["type": "object", "properties": try properties.mapValues(schema), "required": required, "additionalProperties": additionalProperties]
        case let .array(items, minimumItems, maximumItems):
            var result: [String: Any] = ["type": "array", "items": try schema(items)]
            if let minimumItems { result["minItems"] = minimumItems }
            if let maximumItems { result["maxItems"] = maximumItems }
            return result
        case let .string(enumValues, minimumLength, maximumLength):
            var result: [String: Any] = ["type": "string"]
            if !enumValues.isEmpty { result["enum"] = enumValues }
            if let minimumLength { result["minLength"] = minimumLength }
            if let maximumLength { result["maxLength"] = maximumLength }
            return result
        case let .integer(minimum, maximum):
            var result: [String: Any] = ["type": "integer"]
            if let minimum { result["minimum"] = minimum }
            if let maximum { result["maximum"] = maximum }
            return result
        case let .number(minimum, maximum):
            var result: [String: Any] = ["type": "number"]
            if let minimum { result["minimum"] = minimum }
            if let maximum { result["maximum"] = maximum }
            return result
        case .boolean:
            return ["type": "boolean"]
        case let .taggedUnion(discriminator, variants):
            return ["oneOf": try variants.map(schema), "discriminator": ["propertyName": discriminator]]
        }
    }
}

private extension BoneAnthropicToolWire {
    static func validated(_ values: [BoneAgentToolDefinition]) throws -> [BoneAgentToolDefinition] {
        let values = try values.map { try $0.validatedForModelExposure() }
        guard Set(values.map(\.id)).count == values.count,
              Set(values.compactMap(\.wireName)).count == values.count else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return values
    }

    static func contentString(_ value: BoneToolResultContent) throws -> String {
        switch value {
        case let .text(text): return text
        case let .json(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw BoneInferenceError.invalidToolResult
            }
            return text
        }
    }

    static func finishReason(_ value: String?, hasCalls: Bool) -> BoneInferenceFinishReason {
        if hasCalls { return value == "tool_use" ? .toolCalls : .other(providerCode: value) }
        switch value {
        case "end_turn", "stop_sequence": return .stop
        case "max_tokens": return .length
        case "refusal": return .refusal
        case nil: return .other(providerCode: nil)
        default: return .other(providerCode: value)
        }
    }

    static func usage(_ raw: [String: Any]?) throws -> BoneInferenceUsage? {
        guard let raw else { return nil }
        guard let input = raw["input_tokens"] as? Int,
              let output = raw["output_tokens"] as? Int else {
            throw BoneInferenceTransportError.invalidResponse
        }
        do {
            return try BoneInferenceUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: nil,
                reasoningTokens: nil
            ).validated()
        } catch {
            throw BoneInferenceTransportError.invalidResponse
        }
    }
}
