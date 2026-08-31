import Foundation

/// 各 Provider 共享的结构化输出边界；不保存 Schema 或模型结果。
enum BoneStructuredOutputSupport {
    static let internalToolID = "bone.inference.structured-output"
    static let internalToolWireName = "submit_structured_result"

    static func schemaObject(_ schema: BoneToolSchema) throws -> [String: Any] {
        try BoneAnthropicToolWire.schema(schema)
    }

    static func nativeWireFormat(_ format: BoneInferenceResponseFormat) throws -> [String: Any]? {
        switch try format.validated() {
        case .text:
            return nil
        case .jsonObject:
            return ["type": "json_object"]
        case let .jsonSchema(schema, _):
            var wrapper: [String: Any] = [
                "name": schema.name,
                "strict": schema.strict,
                "schema": try schemaObject(schema.root),
            ]
            if let description = schema.description, !description.isEmpty {
                wrapper["description"] = description
            }
            return ["type": "json_schema", "json_schema": wrapper]
        }
    }

    static func geminiSchema(_ format: BoneInferenceResponseFormat) throws -> [String: Any]? {
        switch try format.validated() {
        case .text, .jsonObject:
            return nil
        case let .jsonSchema(schema, _):
            return try schemaObject(schema.root)
        }
    }

    /// 将原生结构化文本转换为统一响应，并在库边界执行本地 Schema 复验。
    /// - Parameters:
    ///   - text: Provider 返回的完整 JSON 文本。
    ///   - schema: 可选的业务无关 JSON Schema；为空时只约束根对象。
    /// - Returns: 已通过本地验证的结构化响应。
    static func structuredResponse(
        from text: String,
        schema: BoneToolSchema? = nil
    ) throws -> BoneInferenceResponse {
        let data = Data(text.utf8)
        if let schema {
            do { try BoneToolSchemaValidator.validate(arguments: data, against: schema) }
            catch { throw BoneInferenceTransportError.invalidResponse }
        } else {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw BoneInferenceTransportError.invalidResponse
            }
        }
        return .structured(.init(data: data))
    }

    static func fallbackTool(for format: BoneInferenceResponseFormat) throws -> BoneAgentToolDefinition {
        let schema: BoneToolSchema
        switch try format.validated() {
        case .text:
            throw BoneInferenceError.invalidStructuredOutputContract
        case .jsonObject:
            // JSON Object 模式无法表达任意字段的强验证，只约束根对象。
            schema = .object(properties: [:], required: [], additionalProperties: true)
        case let .jsonSchema(value, _):
            schema = value.root
        }
        return BoneAgentToolDefinition(
            id: internalToolID,
            version: "1.0.0",
            title: "提交结构化结果",
            summary: "提交最终结构化结果。只能调用一次，不要同时输出正文。",
            wireName: internalToolWireName,
            schemaVersion: 1,
            inputSchema: schema
        )
    }

    static func structuredResponse(
        from response: BoneInferenceResponse,
        schema: BoneToolSchema?
    ) throws -> BoneInferenceResponse {
        let turn: BoneInferenceAssistantTurn
        let finishReason: BoneInferenceFinishReason
        switch response {
        case let .assistantTurn(value, reason, _, refusal, _):
            guard refusal == nil else { throw BoneInferenceTransportError.invalidResponse }
            turn = value
            finishReason = reason
        case let .toolCall(call):
            turn = try .init(content: [.toolCall(call)])
            finishReason = .toolCalls
        case let .finish(value):
            do { turn = try .init(content: [.text(value.text)]) }
            catch { throw BoneInferenceTransportError.invalidResponse }
            finishReason = .stop
        case .structured:
            throw BoneInferenceTransportError.invalidResponse
        }
        if finishReason == .length {
            throw BoneInferenceTransportError.outputTruncated
        }
        let data: Data
        if finishReason == .stop,
           turn.toolCalls.isEmpty,
           turn.structuredOutputs.isEmpty,
           let text = turn.text {
            // 仅结构化输出文本回退进入严格本地归一化；普通 `.text` 响应不会调用本方法。
            // 只剥离无歧义完整外壳，不修复 JSON 内部语法，也不发起付费 repair。
            guard let normalized = BoneStructuredJSONObjectNormalizer.normalize(text) else {
                throw BoneInferenceTransportError.invalidResponse
            }
            data = normalized.data
        } else {
            guard finishReason == .toolCalls,
                  turn.text == nil,
                  turn.structuredOutputs.isEmpty,
                  turn.toolCalls.count == 1,
                  let call = turn.toolCalls.first,
                  call.toolID == internalToolID else {
                throw BoneInferenceTransportError.invalidResponse
            }
            data = call.arguments
        }
        if let schema {
            do { try BoneToolSchemaValidator.validate(arguments: data, against: schema) }
            catch { throw BoneInferenceTransportError.invalidResponse }
        } else {
            guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw BoneInferenceTransportError.invalidResponse
            }
        }
        return .structured(.init(data: data))
    }
}
