import Foundation

/// 请求级受约束输出的完整结果复验边界。
///
/// 不修复、不裁剪、不提取 Provider 输出；任何协议外内容都失败关闭。
enum BoneInferenceOutputConstraintResult {
    static func response(
        from data: Data,
        constraint: BoneInferenceOutputConstraint
    ) throws -> BoneInferenceResponse {
        let validated: BoneInferenceOutputConstraint
        do {
            validated = try constraint.validated()
        } catch {
            throw BoneInferenceTransportError.invalidResponse
        }

        switch validated {
        case let .enumChoice(values):
            guard let text = String(data: data, encoding: .utf8),
                  Data(text.utf8) == data,
                  values.contains(text) else {
                throw BoneInferenceTransportError.invalidResponse
            }
            return .finish(.init(text: text))
        case let .jsonSchema(schema):
            do {
                try BoneToolSchemaValidator.validate(arguments: data, against: schema)
            } catch {
                throw BoneInferenceTransportError.invalidResponse
            }
            return .structured(.init(data: data))
        }
    }
}
