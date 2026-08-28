import Foundation

/// Gemini GenerateContent function calling wire。
enum BoneGeminiToolWire {
    static func definitions(_ values: [BoneAgentToolDefinition]) throws -> [[String: Any]] {
        let definitions = try validated(values)
        return [["functionDeclarations": try definitions.map { definition in
            [
                "name": definition.wireName!,
                "description": definition.summary,
                "parameters": try schema(definition.inputSchema!),
            ]
        }]]
    }

    static func contents(
        _ messages: [BoneInferenceMessage],
        definitions: [BoneAgentToolDefinition],
        continuation: BoneInferenceProviderContinuation?
    ) throws -> [[String: Any]] {
        let definitions = try validated(definitions)
        let names = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.wireName!) })
        var calls: [String: String] = [:]
        var output: [[String: Any]] = []
        let continuationParts = try BoneGeminiContinuation.modelParts(from: continuation)
        let continuationTargetIndex = continuationParts == nil ? nil : messages.lastIndex(where: { $0.assistantTurn != nil })

        for (messageIndex, message) in messages.enumerated() {
            if let text = message.content {
                guard message.role == .user || message.role == .assistant else {
                    throw BoneInferenceError.invalidMessage
                }
                output.append(["role": message.role == .assistant ? "model" : "user", "parts": [["text": text]]])
                continue
            }
            if let turn = message.assistantTurn {
                guard message.role == .assistant, turn.structuredOutputs.isEmpty else {
                    throw BoneInferenceError.invalidMessage
                }
                let parts: [[String: Any]]
                if messageIndex == continuationTargetIndex, let continuationParts {
                    try validateContinuationParts(
                        continuationParts,
                        against: turn,
                        definitions: definitions
                    )
                    parts = continuationParts
                } else {
                    parts = try turn.content.map { block in
                        switch block {
                        case let .text(value): return ["text": value]
                        case .structured: throw BoneInferenceError.invalidMessage
                        case let .toolCall(call):
                            guard let name = names[call.toolID],
                                  let args = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
                                throw BoneInferenceError.invalidMessage
                            }
                            return ["functionCall": ["id": call.id, "name": name, "args": args]]
                        }
                    }
                }
                let functionParts = parts.compactMap { $0["functionCall"] as? [String: Any] }
                guard functionParts.count == turn.toolCalls.count else {
                    throw BoneInferenceError.invalidProviderContinuation
                }
                for (index, function) in functionParts.enumerated() {
                    guard let name = function["name"] as? String,
                          let definition = definitions.first(where: { $0.wireName == name }),
                          let rawID = function["id"] as? String ?? turn.toolCalls[safe: index]?.id,
                          calls[rawID] == nil else {
                        throw BoneInferenceError.invalidProviderContinuation
                    }
                    calls[rawID] = definition.id
                }
                output.append(["role": "model", "parts": parts])
                continue
            }
            if message.toolResult != nil || message.toolResults != nil {
                let batch = try message.requiredToolResults()
                let parts = try batch.results.map { value -> [String: Any] in
                    guard calls[value.callID] == value.toolID,
                          let name = names[value.toolID] else {
                        throw BoneInferenceError.invalidToolResult
                    }
                    let response: Any
                    switch value.content {
                    case let .json(data):
                        response = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                    case let .text(text):
                        response = ["error": text, "isError": value.isError]
                    }
                    return ["functionResponse": ["id": value.callID, "name": name, "response": response]]
                }
                output.append(["role": "user", "parts": parts])
                continue
            }
            throw BoneInferenceError.invalidMessage
        }
        return output
    }

    static func parseResponse(
        _ json: [String: Any],
        definitions: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let definitions = try validated(definitions)
        let stableIDs = Dictionary(uniqueKeysWithValues: definitions.map { ($0.wireName!, $0.id) })
        if let feedback = json["promptFeedback"] as? [String: Any], feedback["blockReason"] != nil {
            throw BoneInferenceTransportError.safetyBlocked
        }
        guard let candidates = json["candidates"] as? [[String: Any]], candidates.count == 1,
              let candidate = candidates.first,
              let contentObject = candidate["content"] as? [String: Any],
              let parts = contentObject["parts"] as? [[String: Any]], !parts.isEmpty else {
            throw BoneInferenceTransportError.invalidResponse
        }
        let finish = (candidate["finishReason"] as? String)?.uppercased()
        if ["SAFETY", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"].contains(finish) {
            throw BoneInferenceTransportError.safetyBlocked
        }
        if finish == "MAX_TOKENS" || finish == "MALFORMED_FUNCTION_CALL" {
            throw BoneInferenceTransportError.invalidResponse
        }
        var blocks: [BoneInferenceAssistantContent] = []
        var localIndex = 0
        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty { blocks.append(.text(text)) }
            if let function = part["functionCall"] as? [String: Any] {
                guard let name = function["name"] as? String,
                      let stableID = stableIDs[name],
                      let args = function["args"] as? [String: Any] else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                let id = function["id"] as? String ?? "gemini-local-\(localIndex)"
                let data = try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
                blocks.append(.toolCall(.init(id: id, toolID: stableID, arguments: data)))
                localIndex += 1
            }
        }
        guard !blocks.isEmpty else { throw BoneInferenceTransportError.invalidResponse }
        let turn: BoneInferenceAssistantTurn
        do { turn = try .init(content: blocks) }
        catch { throw BoneInferenceTransportError.invalidResponse }
        let hasCalls = !turn.toolCalls.isEmpty
        guard !hasCalls || finish == "STOP" else { throw BoneInferenceTransportError.invalidResponse }
        let usage = try parseUsage(json["usageMetadata"] as? [String: Any])
        let continuation = try BoneGeminiContinuation.make(parts: parts)
        return .init(
            assistantTurn: turn,
            finishReason: hasCalls ? .toolCalls : finishReason(finish),
            usage: usage,
            refusal: nil,
            providerContinuation: continuation
        )
    }

    static func schema(_ value: BoneToolSchema) throws -> [String: Any] {
        switch value {
        case let .object(properties, required, additionalProperties):
            return ["type": "OBJECT", "properties": try properties.mapValues(schema), "required": required, "additionalProperties": additionalProperties]
        case let .array(items, minimumItems, maximumItems):
            var value: [String: Any] = ["type": "ARRAY", "items": try schema(items)]
            if let minimumItems { value["minItems"] = minimumItems }
            if let maximumItems { value["maxItems"] = maximumItems }
            return value
        case let .string(enumValues, minimumLength, maximumLength):
            var value: [String: Any] = ["type": "STRING"]
            if !enumValues.isEmpty { value["enum"] = enumValues }
            if let minimumLength { value["minLength"] = minimumLength }
            if let maximumLength { value["maxLength"] = maximumLength }
            return value
        case let .integer(minimum, maximum):
            var value: [String: Any] = ["type": "INTEGER"]
            if let minimum { value["minimum"] = minimum }
            if let maximum { value["maximum"] = maximum }
            return value
        case let .number(minimum, maximum):
            var value: [String: Any] = ["type": "NUMBER"]
            if let minimum { value["minimum"] = minimum }
            if let maximum { value["maximum"] = maximum }
            return value
        case .boolean: return ["type": "BOOLEAN"]
        case let .taggedUnion(discriminator, variants):
            return ["oneOf": try variants.map(schema), "discriminator": ["propertyName": discriminator]]
        }
    }
}

private extension BoneGeminiToolWire {
    static func validateContinuationParts(
        _ parts: [[String: Any]],
        against turn: BoneInferenceAssistantTurn,
        definitions: [BoneAgentToolDefinition]
    ) throws {
        let names = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0.wireName!) })
        guard parts.count == turn.content.count else {
            throw BoneInferenceError.invalidProviderContinuation
        }
        for (part, block) in zip(parts, turn.content) {
            switch block {
            case let .text(expectedText):
                guard part["text"] as? String == expectedText,
                      part["functionCall"] == nil else {
                    throw BoneInferenceError.invalidProviderContinuation
                }
            case .structured:
                throw BoneInferenceError.invalidProviderContinuation
            case let .toolCall(call):
                guard let function = part["functionCall"] as? [String: Any],
                      let expectedName = names[call.toolID],
                      function["name"] as? String == expectedName,
                      (function["id"] as? String ?? call.id) == call.id,
                      let rawArguments = function["args"] as? [String: Any],
                      let expectedArguments = try? JSONSerialization.jsonObject(with: call.arguments) as? [String: Any],
                      NSDictionary(dictionary: rawArguments).isEqual(to: expectedArguments) else {
                    throw BoneInferenceError.invalidProviderContinuation
                }
            }
        }
    }

    static func validated(_ values: [BoneAgentToolDefinition]) throws -> [BoneAgentToolDefinition] {
        let result = try values.map { try $0.validatedForModelExposure() }
        guard Set(result.map(\.id)).count == result.count,
              Set(result.compactMap(\.wireName)).count == result.count else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return result
    }

    static func parseUsage(_ raw: [String: Any]?) throws -> BoneInferenceUsage? {
        guard let raw else { return nil }
        guard let input = raw["promptTokenCount"] as? Int,
              let output = raw["candidatesTokenCount"] as? Int else {
            throw BoneInferenceTransportError.invalidResponse
        }
        do {
            return try BoneInferenceUsage(
                inputTokens: input,
                outputTokens: output,
                cachedInputTokens: raw["cachedContentTokenCount"] as? Int,
                reasoningTokens: raw["thoughtsTokenCount"] as? Int
            ).validated()
        } catch { throw BoneInferenceTransportError.invalidResponse }
    }

    static func finishReason(_ value: String?) -> BoneInferenceFinishReason {
        switch value {
        case "STOP": return .stop
        case "MAX_TOKENS": return .length
        case "SAFETY": return .safety
        case nil: return .other(providerCode: nil)
        default: return .other(providerCode: value)
        }
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
