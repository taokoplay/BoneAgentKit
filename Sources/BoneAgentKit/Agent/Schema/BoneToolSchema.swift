import Foundation

/// Provider 无关、可版本化的 Tool 输入 Schema。
///
/// 首版只表达三类真实 Provider 能无损或显式降级处理的 JSON Schema 子集，
/// 不接受任意 Provider JSON 或 `[String: Any]` 作为公开契约。
public indirect enum BoneToolSchema: Codable, Equatable, Sendable {
    case object(
        properties: [String: BoneToolSchema],
        required: [String],
        additionalProperties: Bool
    )
    case array(items: BoneToolSchema, minimumItems: Int?, maximumItems: Int?)
    case string(enumValues: [String], minimumLength: Int?, maximumLength: Int?)
    case integer(minimum: Int?, maximum: Int?)
    case number(minimum: Double?, maximum: Double?)
    case boolean
    case taggedUnion(discriminator: String, variants: [BoneToolSchema])
}

/// Tool Schema 和模型参数验证的稳定安全分类。
public enum BoneToolSchemaSafeReason: String, Codable, Equatable, Sendable {
    case invalidSchema
    case schemaTooLarge
    case invalidToolIdentity
    case missingInputSchema
    case argumentsMismatch
    case argumentsTooLarge
}

/// Tool Schema Interface 的稳定错误；不携带 Schema、参数或业务字段名。
public enum BoneToolSchemaError: Error, Equatable, Sendable {
    case invalidSchema
    case schemaTooLarge
    case invalidToolIdentity
    case missingInputSchema
    case argumentsMismatch
    case argumentsTooLarge

    public var safeReason: BoneToolSchemaSafeReason {
        switch self {
        case .invalidSchema: return .invalidSchema
        case .schemaTooLarge: return .schemaTooLarge
        case .invalidToolIdentity: return .invalidToolIdentity
        case .missingInputSchema: return .missingInputSchema
        case .argumentsMismatch: return .argumentsMismatch
        case .argumentsTooLarge: return .argumentsTooLarge
        }
    }
}
