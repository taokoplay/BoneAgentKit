import Foundation

/// 结构化输出无法使用原生 Provider 契约时允许的安全降级方式。
public enum BoneInferenceStructuredOutputFallbackPolicy: String, Codable, Equatable, Sendable {
    /// 仅接受 Provider 原生 JSON 输出；不支持时在联网前失败。
    case requireNative
    /// 原生能力不可用时，允许 BoneAgentKit 内部使用一次强制 Tool Call 交付结果。
    case nativeOrToolCall
}

/// 供应商无关、受限且可验证的 JSON Schema 输出契约。
public struct BoneInferenceJSONSchema: Codable, Equatable, Sendable {
    public let name: String
    public let description: String?
    public let root: BoneToolSchema
    public let strict: Bool

    public init(
        name: String,
        description: String? = nil,
        root: BoneToolSchema,
        strict: Bool = true
    ) {
        self.name = name
        self.description = description
        self.root = root
        self.strict = strict
    }

    public func validated() throws -> Self {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard (1...64).contains(name.count),
              name.unicodeScalars.allSatisfy(allowed.contains),
              description.map({ $0.count <= 1_024 }) != false,
              case .object = root else {
            throw BoneInferenceError.invalidStructuredOutputContract
        }
        do { try BoneToolSchemaValidator.validateDefinition(root) }
        catch { throw BoneInferenceError.invalidStructuredOutputContract }
        return self
    }
}

/// 业务只声明响应意图；具体 Provider 字段由各协议适配器负责。
public enum BoneInferenceResponseFormat: Codable, Equatable, Sendable {
    case text
    case jsonObject(fallback: BoneInferenceStructuredOutputFallbackPolicy)
    case jsonSchema(BoneInferenceJSONSchema, fallback: BoneInferenceStructuredOutputFallbackPolicy)

    public func validated() throws -> Self {
        switch self {
        case .text, .jsonObject:
            return self
        case let .jsonSchema(schema, _):
            _ = try schema.validated()
            return self
        }
    }

    public var isStructured: Bool {
        if case .text = self { return false }
        return true
    }

    var fallbackPolicy: BoneInferenceStructuredOutputFallbackPolicy? {
        switch self {
        case .text: return nil
        case let .jsonObject(fallback), let .jsonSchema(_, fallback): return fallback
        }
    }

    var schema: BoneInferenceJSONSchema? {
        guard case let .jsonSchema(schema, _) = self else { return nil }
        return schema
    }
}
