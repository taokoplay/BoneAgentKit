import BoneAgentKit
import Foundation

/// 可由 Runtime Grammar 约束的判别联合 Tool Envelope。
public struct BoneLlamaConstrainedJSONToolEnvelopeCodec: BoneLlamaToolEnvelopeCoding, Sendable {
    public let identity = BoneLlamaToolEnvelopeIdentity(
        id: "bone.constrained-json-tool-envelope",
        version: "2"
    )

    public init() {}

    public func systemInstructions(tools: [BoneAgentToolDefinition]) throws -> String {
        let definitions = try BoneLlamaJSONToolEnvelopeCodec.validatedTools(tools)
            .map(BoneLlamaJSONToolEnvelopeCodec.definitionObject)
        return """
        You may call only the tools declared below.
        Tools: \(try BoneLlamaJSONToolEnvelopeCodec.jsonString(definitions))
        Output exactly one JSON object. For a final answer use {"type":"final","content":"answer"}. To call tools use {"type":"tool_calls","tool_calls":[{"id":"unique-call-id","name":"tool_wire_name","arguments":{}}]}. Do not emit surrounding text.
        """
    }

    public func encodeAssistantTurn(
        _ turn: BoneInferenceAssistantTurn,
        tools: [BoneAgentToolDefinition]
    ) throws -> String {
        let validated = try BoneLlamaJSONToolEnvelopeCodec.validatedTools(tools)
        let byID = Dictionary(uniqueKeysWithValues: validated.map { ($0.id, $0) })
        var text = ""
        var calls: [[String: Any]] = []
        for block in turn.content {
            switch block {
            case let .text(value):
                text += value
            case .structured:
                throw BoneLlamaAdapterError.unsupportedRequest
            case let .toolCall(call):
                guard let tool = byID[call.toolID], let name = tool.wireName,
                      let schema = tool.inputSchema,
                      let arguments = try JSONSerialization.jsonObject(with: call.arguments) as? [String: Any] else {
                    throw BoneLlamaAdapterError.unsupportedRequest
                }
                do { try BoneToolSchemaValidator.validate(arguments: call.arguments, against: schema) }
                catch { throw BoneLlamaAdapterError.unsupportedRequest }
                calls.append(["id": call.id, "name": name, "arguments": arguments])
            }
        }
        if !calls.isEmpty {
            guard text.isEmpty else { throw BoneLlamaAdapterError.unsupportedRequest }
            return try BoneLlamaJSONToolEnvelopeCodec.jsonString([
                "type": "tool_calls",
                "tool_calls": calls,
            ])
        }
        guard !text.isEmpty else { throw BoneLlamaAdapterError.unsupportedRequest }
        return try BoneLlamaJSONToolEnvelopeCodec.jsonString([
            "type": "final",
            "content": text,
        ])
    }

    public func encodeToolResults(
        _ results: BoneInferenceToolResultBatch,
        tools: [BoneAgentToolDefinition]
    ) throws -> String {
        try BoneLlamaJSONToolEnvelopeCodec().encodeToolResults(results, tools: tools)
    }

    public func generationConstraint(
        tools: [BoneAgentToolDefinition]
    ) throws -> BoneLlamaGenerationConstraint? {
        .jsonSchema(try Self.outputSchema(tools: tools))
    }

    public func decode(
        output: String,
        availableTools: [BoneAgentToolDefinition]
    ) throws -> BoneInferenceResponse {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BoneLlamaAdapterError.emptyResponse }
        do {
            let data = Data(text.utf8)
            try BoneToolSchemaValidator.validate(
                arguments: data,
                against: Self.outputSchema(tools: availableTools)
            )
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = envelope["type"] as? String else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            if type == "final" {
                guard envelope.count == 2,
                      let content = envelope["content"] as? String,
                      !content.isEmpty else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                return .finish(.init(text: content))
            }
            guard type == "tool_calls",
                  envelope.count == 2,
                  let rawCalls = envelope["tool_calls"] as? [[String: Any]],
                  !rawCalls.isEmpty else {
                throw BoneLlamaAdapterError.invalidToolCallingResponse
            }
            let tools = try BoneLlamaJSONToolEnvelopeCodec.validatedTools(availableTools)
            let stableIDs = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
                tool.wireName.map { ($0, tool.id) }
            })
            let schemas = Dictionary(uniqueKeysWithValues: tools.compactMap { tool in
                tool.inputSchema.map { (tool.id, $0) }
            })
            var callIDs = Set<String>()
            var blocks: [BoneInferenceAssistantContent] = []
            for rawCall in rawCalls {
                guard rawCall.count == 3,
                      let id = rawCall["id"] as? String,
                      !id.isEmpty,
                      callIDs.insert(id).inserted,
                      let name = rawCall["name"] as? String,
                      let toolID = stableIDs[name],
                      let arguments = rawCall["arguments"] as? [String: Any],
                      let schema = schemas[toolID] else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                let argumentsData = try JSONSerialization.data(
                    withJSONObject: arguments,
                    options: [.sortedKeys]
                )
                try BoneToolSchemaValidator.validate(arguments: argumentsData, against: schema)
                blocks.append(.toolCall(.init(id: id, toolID: toolID, arguments: argumentsData)))
            }
            return .init(
                assistantTurn: try .init(content: blocks),
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

private extension BoneLlamaConstrainedJSONToolEnvelopeCodec {
    static func outputSchema(tools: [BoneAgentToolDefinition]) throws -> BoneToolSchema {
        let tools = try BoneLlamaJSONToolEnvelopeCodec.validatedTools(tools)
        let final = BoneToolSchema.object(
            properties: [
                "type": .string(enumValues: ["final"], minimumLength: nil, maximumLength: nil),
                "content": .string(enumValues: [], minimumLength: nil, maximumLength: nil),
            ],
            required: ["type", "content"],
            additionalProperties: false
        )
        let callVariants: [BoneToolSchema] = tools.compactMap { tool in
            guard let wireName = tool.wireName, let arguments = tool.inputSchema else { return nil }
            return .object(
                properties: [
                    "id": .string(enumValues: [], minimumLength: nil, maximumLength: nil),
                    "name": .string(enumValues: [wireName], minimumLength: nil, maximumLength: nil),
                    "arguments": arguments,
                ],
                required: ["id", "name", "arguments"],
                additionalProperties: false
            )
        }
        let callItem: BoneToolSchema
        if callVariants.count == 1 {
            callItem = callVariants[0]
        } else {
            callItem = .taggedUnion(discriminator: "name", variants: callVariants)
        }
        let calls = BoneToolSchema.object(
            properties: [
                "type": .string(enumValues: ["tool_calls"], minimumLength: nil, maximumLength: nil),
                "tool_calls": .array(
                    items: callItem,
                    minimumItems: nil,
                    maximumItems: nil
                ),
            ],
            required: ["type", "tool_calls"],
            additionalProperties: false
        )
        let schema = BoneToolSchema.taggedUnion(
            discriminator: "type",
            variants: [final, calls]
        )
        try BoneToolSchemaValidator.validateDefinition(schema)
        return schema
    }
}
