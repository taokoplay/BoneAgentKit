import Foundation

/// OpenAI Chat Completions Tool wire 的内部 clean-room 映射。
enum BoneOpenAIToolWire {
    /// 非流式 Tool 响应的安全形态分类；只检查结构，不保留模型生成值。
    static func failureStage(
        _ json: [String: Any],
        definitions: [BoneAgentToolDefinition]
    ) -> BoneInferenceOpenAIFailureStage {
        guard json["error"] == nil else { return .eventError }
        guard let choices = json["choices"] as? [[String: Any]], choices.count == 1,
              let choice = choices.first else { return .choicesShape }
        if let index = choice["index"] as? Int, index != 0 { return .choiceIndex }
        guard let message = choice["message"] as? [String: Any] else { return .deltaShape }
        let knownNames = Set(definitions.compactMap(\.wireName))
        if let calls = message["tool_calls"] as? [[String: Any]] {
            var ids = Set<String>()
            for call in calls {
                guard call["type"] as? String == "function",
                      let id = call["id"] as? String,
                      ids.insert(id).inserted,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String,
                      knownNames.contains(name),
                      let arguments = function["arguments"] as? String else {
                    return .toolIdentity
                }
                guard (try? JSONSerialization.jsonObject(with: Data(arguments.utf8))) is [String: Any] else {
                    return .toolArgumentsJSON
                }
            }
        }
        guard let reason = choice["finish_reason"] as? String else { return .finishReason }
        if message["tool_calls"] != nil,
           reason != "tool_calls", reason != "function_call" { return .finishReason }
        if let usage = json["usage"] {
            guard let raw = usage as? [String: Any],
                  raw["prompt_tokens"] is Int,
                  raw["completion_tokens"] is Int else { return .usageShape }
        }
        return .assistantTurn
    }

    static func definitions(_ values: [BoneAgentToolDefinition]) throws -> [[String: Any]] {
        try validatedDefinitions(values).map { definition in
            [
                "type": "function",
                "function": [
                    "name": definition.wireName!,
                    "description": definition.summary,
                    "parameters": try schema(definition.inputSchema!),
                ] as [String: Any],
            ]
        }
    }

    static func messages(
        _ values: [BoneInferenceMessage],
        definitions: [BoneAgentToolDefinition]
    ) throws -> [[String: Any]] {
        let definitions = try validatedDefinitions(definitions)
        let wireNames = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.wireName!) })
        var result: [[String: Any]] = []
        var knownCallIDs: [String: String] = [:]

        for message in values {
            if let content = message.content {
                guard message.assistantTurn == nil,
                      message.toolResult == nil,
                      message.toolResults == nil,
                      message.role != .tool else {
                    throw BoneInferenceError.invalidMessage
                }
                result.append(["role": message.role.rawValue, "content": content])
                continue
            }
            if let turn = message.assistantTurn {
                guard message.role == .assistant,
                      message.toolResult == nil,
                      message.toolResults == nil else {
                    throw BoneInferenceError.invalidMessage
                }
                var wire: [String: Any] = ["role": "assistant"]
                if let text = turn.text { wire["content"] = text }
                if !turn.structuredOutputs.isEmpty { throw BoneInferenceError.invalidMessage }
                let calls = try turn.toolCalls.map { call -> [String: Any] in
                    guard let wireName = wireNames[call.toolID], knownCallIDs[call.id] == nil else {
                        throw BoneInferenceError.invalidMessage
                    }
                    knownCallIDs[call.id] = call.toolID
                    return [
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": wireName,
                            "arguments": try jsonObjectString(call.arguments),
                        ],
                    ]
                }
                if !calls.isEmpty { wire["tool_calls"] = calls }
                guard wire["content"] != nil || wire["tool_calls"] != nil else {
                    throw BoneInferenceError.invalidMessage
                }
                result.append(wire)
                continue
            }
            if message.toolResult != nil || message.toolResults != nil {
                guard message.role == .tool else { throw BoneInferenceError.invalidMessage }
                let batch = try message.requiredToolResults()
                for toolResult in batch.results {
                    guard knownCallIDs[toolResult.callID] == toolResult.toolID,
                          wireNames[toolResult.toolID] != nil else {
                        throw BoneInferenceError.invalidToolResult
                    }
                    result.append([
                        "role": "tool",
                        "tool_call_id": toolResult.callID,
                        "content": try contentString(toolResult.content),
                    ])
                }
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
        let definitions = try validatedDefinitions(definitions)
        let stableIDs = Dictionary(uniqueKeysWithValues: definitions.map { ($0.wireName!, $0.id) })
        guard let choices = json["choices"] as? [[String: Any]],
              choices.count == 1,
              let choice = choices.first,
              let message = choice["message"] as? [String: Any] else {
            throw BoneInferenceTransportError.invalidResponse
        }

        var content: [BoneInferenceAssistantContent] = []
        if let text = textContent(message["content"]), !text.isEmpty { content.append(.text(text)) }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            for call in calls {
                guard call["type"] as? String == "function",
                      let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let wireName = function["name"] as? String,
                      let stableID = stableIDs[wireName],
                      let arguments = function["arguments"] as? String else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                let data = Data(arguments.utf8)
                guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                content.append(.toolCall(.init(id: id, toolID: stableID, arguments: data)))
            }
        }
        guard !content.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        let turn: BoneInferenceAssistantTurn
        do { turn = try .init(content: content) }
        catch { throw BoneInferenceTransportError.invalidResponse }
        let reason = finishReason(choice["finish_reason"] as? String, hasCalls: !turn.toolCalls.isEmpty)
        if reason == .length { throw BoneInferenceTransportError.outputTruncated }
        let usage = try usage(json["usage"] as? [String: Any])
        let refusal = refusal(message["refusal"])
        return .init(
            assistantTurn: turn,
            finishReason: reason,
            usage: usage,
            refusal: refusal,
            providerContinuation: nil
        )
    }
}

private extension BoneOpenAIToolWire {
    static func validatedDefinitions(_ values: [BoneAgentToolDefinition]) throws -> [BoneAgentToolDefinition] {
        let definitions = try values.map { try $0.validatedForModelExposure() }
        guard Set(definitions.map(\.id)).count == definitions.count,
              Set(definitions.compactMap(\.wireName)).count == definitions.count else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return definitions
    }

    static func schema(_ value: BoneToolSchema) throws -> [String: Any] {
        switch value {
        case let .object(properties, required, additionalProperties):
            return [
                "type": "object",
                "properties": try properties.mapValues(schema),
                "required": required,
                "additionalProperties": additionalProperties,
            ]
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

    static func jsonObjectString(_ data: Data) throws -> String {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let value = String(data: data, encoding: .utf8) else {
            throw BoneInferenceError.invalidMessage
        }
        return value
    }

    static func contentString(_ value: BoneToolResultContent) throws -> String {
        switch value {
        case let .text(text): return text
        case let .json(data):
            guard let string = String(data: data, encoding: .utf8) else {
                throw BoneInferenceError.invalidToolResult
            }
            return string
        }
    }

    static func textContent(_ raw: Any?) -> String? {
        if raw is NSNull || raw == nil { return nil }
        if let text = raw as? String { return text }
        if let parts = raw as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                guard part["type"] as? String == "text" else { return nil }
                return part["text"] as? String
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    static func finishReason(_ value: String?, hasCalls: Bool) -> BoneInferenceFinishReason {
        switch value {
        case "stop": return .stop
        case "tool_calls", "function_call": return hasCalls ? .toolCalls : .other(providerCode: value)
        case "length": return .length
        case "content_filter": return .contentFilter
        case nil: return .other(providerCode: nil)
        default: return .other(providerCode: value)
        }
    }

    static func usage(_ raw: [String: Any]?) throws -> BoneInferenceUsage? {
        guard let raw else { return nil }
        guard let input = raw["prompt_tokens"] as? Int,
              let output = raw["completion_tokens"] as? Int else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let cached = (raw["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
        let reasoning = (raw["completion_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int
        do {
            return try BoneInferenceUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: cached,
                reasoningTokens: reasoning
            ).validated()
        } catch {
            throw BoneInferenceTransportError.invalidResponse
        }
    }

    static func refusal(_ raw: Any?) -> BoneInferenceRefusal? {
        guard raw != nil, !(raw is NSNull) else { return nil }
        return .unknown
    }
}
