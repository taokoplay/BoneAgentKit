import BoneAgentKit
import Foundation

/// 严格 JSON Tool Envelope；不包含任何模型会话模板标记。
public struct BoneLlamaJSONToolEnvelopeCodec: BoneLlamaToolEnvelopeCoding, Sendable {
    public let identity = BoneLlamaToolEnvelopeIdentity(id: "bone.json-tool-envelope", version: "1")

    public init() {}

    public func systemInstructions(tools: [BoneAgentToolDefinition]) throws -> String {
        let definitions = try Self.validatedTools(tools).map(Self.definitionObject)
        return """
        You may call only the tools declared below.
        Tools: \(try Self.jsonString(definitions))
        To call tools, output only one JSON object with this exact shape and no surrounding text: {"tool_calls":[{"id":"unique-call-id","name":"tool_wire_name","arguments":{}}]}
        `tool_calls` must be a non-empty array. Each `id` must be unique, each `name` must match a declared tool, and each `arguments` value must be a JSON object. Multiple calls are allowed. If no tool is needed, answer with plain text and do not emit a JSON object.
        """
    }

    public func encodeAssistantTurn(
        _ turn: BoneInferenceAssistantTurn,
        tools: [BoneAgentToolDefinition]
    ) throws -> String {
        try Self.assistantContent(
            turn,
            toolsByID: Dictionary(uniqueKeysWithValues: Self.validatedTools(tools).map { ($0.id, $0) })
        )
    }

    public func encodeToolResults(
        _ results: BoneInferenceToolResultBatch,
        tools: [BoneAgentToolDefinition]
    ) throws -> String {
        try Self.toolResultContent(
            results,
            toolsByID: Dictionary(uniqueKeysWithValues: Self.validatedTools(tools).map { ($0.id, $0) })
        )
    }

    public func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
        let tools = try Self.validatedTools(availableTools)
        guard text.first == "{" else {
            if text.first == "[" || text.contains("\"tool_calls\"") {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            return .finish(.init(text: text))
        }

        do {
            guard let envelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  envelope.count == 1,
                  let rawCalls = envelope["tool_calls"] as? [[String: Any]],
                  !rawCalls.isEmpty,
                  rawCalls.count <= BoneInferenceAssistantTurn.maximumToolCallCount else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            let stableIDs = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
                tool.wireName.map { ($0, tool.id) }
            })
            let schemas = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
                tool.inputSchema.map { (tool.id, $0) }
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
                      let schema = schemas[toolID],
                      JSONSerialization.isValidJSONObject(arguments) else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                try BoneToolSchemaValidator.validate(arguments: data, against: schema)
                content.append(.toolCall(.init(id: id, toolID: toolID, arguments: data)))
            }
            return .init(
                assistantTurn: try .init(content: content),
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

extension BoneLlamaJSONToolEnvelopeCodec {
    static func validatedTools(_ values: [BoneAgentToolDefinition]) throws -> [BoneAgentToolDefinition] {
        let tools = try values.map { try $0.validatedForModelExposure() }
        guard Set(tools.map(\.id)).count == tools.count,
              Set(tools.compactMap(\.wireName)).count == tools.count else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return tools
    }

    static func assistantContent(
        _ turn: BoneInferenceAssistantTurn,
        toolsByID: [String: BoneAgentToolDefinition]
    ) throws -> String {
        var text = ""
        var calls: [[String: Any]] = []
        for block in turn.content {
            switch block {
            case let .text(value): text += value
            case .structured: throw BoneLlamaAdapterError.unsupportedRequest
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
            case let .text(value): content = value; contentType = "text"
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

    static func definitionObject(_ tool: BoneAgentToolDefinition) throws -> [String: Any] {
        guard let name = tool.wireName, let schema = tool.inputSchema else {
            throw BoneToolSchemaError.invalidToolIdentity
        }
        return ["name": name, "description": tool.summary, "parameters": try schemaObject(schema)]
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
        case .boolean: return ["type": "boolean"]
        case let .taggedUnion(discriminator, variants):
            return [
                "oneOf": try variants.map(schemaObject),
                "discriminator": ["propertyName": discriminator],
            ]
        }
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
