import BoneAgentKit
import Foundation

/// A strict ChatML Tool Calling protocol for models trained or prompted to emit a JSON envelope.
///
/// Tool calls must occupy the complete model output and use this shape:
/// `{"tool_calls":[{"id":"...","name":"wire_name","arguments":{...}}]}`.
/// Models that use a different native chat template should install a different
/// `BoneLlamaToolCalling` implementation.
public struct BoneLlamaJSONToolCallingCodec: BoneLlamaToolCalling, Sendable {
    public init() {}

    public func encode(request: BoneInferenceRequest) throws -> String {
        guard !request.messages.isEmpty,
              request.providerContinuation == nil,
              request.reasoningDisclosure == .hidden,
              request.responseFormat == .text else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        let tools = try Self.validatedTools(request.availableTools)
        let definitions = try tools.map(Self.definitionObject)
        let definitionsJSON = try Self.jsonString(definitions)
        let instructions = """
        You may call only the tools declared below.
        Tools: \(definitionsJSON)
        To call tools, output only one JSON object with this exact shape and no surrounding text: {"tool_calls":[{"id":"unique-call-id","name":"tool_wire_name","arguments":{}}]}
        `tool_calls` must be a non-empty array. Each `id` must be unique, each `name` must match a declared tool, and each `arguments` value must be a JSON object. Multiple calls are allowed. If no tool is needed, answer with plain text and do not emit a JSON object.
        """

        let byID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        var knownCallIDs: [String: String] = [:]
        var prompt = Self.chatML(role: .system, content: instructions)
        for message in request.messages {
            switch message.role {
            case .system, .user:
                guard let content = message.content, !content.isEmpty else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                prompt += Self.chatML(role: message.role, content: content)
            case .assistant:
                if let content = message.content, !content.isEmpty {
                    prompt += Self.chatML(role: .assistant, content: content)
                } else if let turn = message.assistantTurn {
                    for call in turn.toolCalls {
                        guard knownCallIDs[call.id] == nil else {
                            throw BoneLlamaAdapterError.unsupportedRequest
                        }
                        knownCallIDs[call.id] = call.toolID
                    }
                    prompt += Self.chatML(role: .assistant, content: try Self.assistantContent(turn, toolsByID: byID))
                } else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
            case .tool:
                let batch: BoneInferenceToolResultBatch
                do { batch = try message.requiredToolResults() }
                catch { throw BoneLlamaAdapterError.unsupportedRequest }
                guard batch.results.allSatisfy({ knownCallIDs[$0.callID] == $0.toolID }) else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                prompt += Self.chatML(role: .tool, content: try Self.toolResultContent(batch, toolsByID: byID))
            }
        }
        prompt += "<|im_start|>assistant\n"
        return prompt
    }

    public func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }

        let tools: [BoneAgentToolDefinition]
        do { tools = try Self.validatedTools(availableTools) }
        catch { throw error }
        let first = text.first
        guard first == "{" else {
            if first == "[" || text.contains("\"tool_calls\"") {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            return .finish(.init(text: text))
        }

        do {
            let data = Data(text.utf8)
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  envelope.count == 1,
                  let rawCalls = envelope["tool_calls"] as? [[String: Any]],
                  !rawCalls.isEmpty,
                  rawCalls.count <= BoneInferenceAssistantTurn.maximumToolCallCount else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            let stableIDs = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
                tool.wireName.map { ($0, tool.id) }
            })
            var callIDs = Set<String>()
            var content: [BoneInferenceAssistantContent] = []
            for rawCall in rawCalls {
                guard rawCall.count == 3,
                      let id = rawCall["id"] as? String,
                      !id.isEmpty,
                      callIDs.insert(id).inserted,
                      let name = rawCall["name"] as? String,
                      let toolID = stableIDs[name],
                      let arguments = rawCall["arguments"] as? [String: Any],
                      JSONSerialization.isValidJSONObject(arguments) else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                let argumentData = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                guard let schema = tools.first(where: { $0.id == toolID })?.inputSchema else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                try BoneToolSchemaValidator.validate(arguments: argumentData, against: schema)
                content.append(.toolCall(.init(id: id, toolID: toolID, arguments: argumentData)))
            }
            let turn = try BoneInferenceAssistantTurn(content: content)
            return .init(
                assistantTurn: turn,
                finishReason: .toolCalls,
                usage: nil,
                refusal: nil,
                providerContinuation: nil
            )
        } catch let error as BoneLlamaAdapterError {
            throw error
        } catch {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }
}

private extension BoneLlamaJSONToolCallingCodec {
    static func validatedTools(_ values: [BoneAgentToolDefinition]) throws -> [BoneAgentToolDefinition] {
        let tools = try values.map { try $0.validatedForModelExposure() }
        guard Set(tools.map(\.id)).count == tools.count,
              Set(tools.compactMap(\.wireName)).count == tools.count else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return tools
    }

    static func definitionObject(_ tool: BoneAgentToolDefinition) throws -> [String: Any] {
        guard let name = tool.wireName, let inputSchema = tool.inputSchema else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return [
            "name": name,
            "description": tool.summary,
            "parameters": try schemaObject(inputSchema),
        ]
    }

    static func schemaObject(_ schema: BoneToolSchema) throws -> [String: Any] {
        switch schema {
        case let .object(properties, required, additionalProperties):
            return [
                "type": "object",
                "properties": try properties.mapValues(schemaObject),
                "required": required,
                "additionalProperties": additionalProperties,
            ]
        case let .array(items, minimumItems, maximumItems):
            var value: [String: Any] = ["type": "array", "items": try schemaObject(items)]
            if let minimumItems { value["minItems"] = minimumItems }
            if let maximumItems { value["maxItems"] = maximumItems }
            return value
        case let .string(enumValues, minimumLength, maximumLength):
            var value: [String: Any] = ["type": "string"]
            if !enumValues.isEmpty { value["enum"] = enumValues }
            if let minimumLength { value["minLength"] = minimumLength }
            if let maximumLength { value["maxLength"] = maximumLength }
            return value
        case let .integer(minimum, maximum):
            var value: [String: Any] = ["type": "integer"]
            if let minimum { value["minimum"] = minimum }
            if let maximum { value["maximum"] = maximum }
            return value
        case let .number(minimum, maximum):
            var value: [String: Any] = ["type": "number"]
            if let minimum { value["minimum"] = minimum }
            if let maximum { value["maximum"] = maximum }
            return value
        case .boolean:
            return ["type": "boolean"]
        case let .taggedUnion(discriminator, variants):
            return [
                "oneOf": try variants.map(schemaObject),
                "discriminator": ["propertyName": discriminator],
            ]
        }
    }

    static func assistantContent(
        _ turn: BoneInferenceAssistantTurn,
        toolsByID: [String: BoneAgentToolDefinition]
    ) throws -> String {
        var text = ""
        var calls: [[String: Any]] = []
        for block in turn.content {
            switch block {
            case let .text(value):
                text += value
            case .structured:
                throw BoneLlamaAdapterError.unsupportedRequest
            case let .toolCall(call):
                guard let tool = toolsByID[call.toolID], let name = tool.wireName,
                      let schema = tool.inputSchema,
                      let arguments = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                do { try BoneToolSchemaValidator.validate(arguments: call.arguments, against: schema) }
                catch { throw BoneLlamaAdapterError.unsupportedRequest }
                calls.append(["id": call.id, "name": name, "arguments": arguments])
            }
        }
        if calls.isEmpty { return text }
        var envelope: [String: Any] = ["tool_calls": calls]
        if !text.isEmpty { envelope["content"] = text }
        return try jsonString(envelope)
    }

    static func toolResultContent(
        _ batch: BoneInferenceToolResultBatch,
        toolsByID: [String: BoneAgentToolDefinition]
    ) throws -> String {
        let results: [[String: Any]] = try batch.results.map { result in
            guard let tool = toolsByID[result.toolID], let name = tool.wireName else {
                throw BoneLlamaAdapterError.unsupportedRequest
            }
            let content: Any
            let contentType: String
            switch result.content {
            case let .text(value):
                content = value
                contentType = "text"
            case let .json(data):
                content = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
                contentType = "json"
            }
            return [
                "id": result.callID,
                "name": name,
                "content": content,
                "content_type": contentType,
                "is_error": result.isError,
                "ordinal": result.ordinal,
            ]
        }
        return try jsonString(["tool_results": results])
    }

    static func chatML(role: BoneInferenceMessageRole, content: String) -> String {
        "<|im_start|>\(role.rawValue)\n\(content)<|im_end|>\n"
    }

    static func jsonString(_ value: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw BoneLlamaAdapterError.unsupportedRequest
        }
        return string
    }
}
