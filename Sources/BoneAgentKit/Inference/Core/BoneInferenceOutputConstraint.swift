import Foundation

/// Provider 无关的受约束输出契约；具体 Engine 必须原生实现或在调用前拒绝。
public enum BoneInferenceOutputConstraint: Codable, Equatable, Sendable {
    public static let maximumEnumChoiceCount = 128
    public static let maximumEnumChoiceLength = 256

    case jsonSchema(BoneToolSchema)
    case enumChoice([String])

    public func validated() throws -> Self {
        switch self {
        case let .jsonSchema(schema):
            do {
                try BoneToolSchemaValidator.validateDefinition(schema)
            } catch {
                throw BoneInferenceError.invalidOutputConstraint
            }
        case let .enumChoice(values):
            guard !values.isEmpty,
                  values.count <= Self.maximumEnumChoiceCount,
                  Set(values).count == values.count,
                  values.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumEnumChoiceLength }) else {
                throw BoneInferenceError.invalidOutputConstraint
            }
        }
        return self
    }
}
