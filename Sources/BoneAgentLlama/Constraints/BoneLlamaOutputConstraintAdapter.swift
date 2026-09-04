import BoneAgentKit
import Foundation

public enum BoneLlamaOutputConstraintAdapter {
    public static func map(
        _ constraint: BoneInferenceOutputConstraint
    ) throws -> BoneLlamaGenerationConstraint {
        let validated: BoneInferenceOutputConstraint
        do { validated = try constraint.validated() }
        catch { throw BoneLlamaAdapterError.invalidGenerationControl }
        switch validated {
        case let .enumChoice(values): return .enumChoice(values)
        case let .jsonSchema(schema): return .jsonSchema(schema)
        }
    }

    public static func decode(
        _ output: String,
        constraint: BoneInferenceOutputConstraint
    ) throws -> BoneInferenceResponse {
        do {
            switch try constraint.validated() {
            case let .enumChoice(values):
                guard values.contains(output) else {
                    throw BoneLlamaAdapterError.invalidToolCallingResponse
                }
                return .finish(.init(text: output))
            case let .jsonSchema(schema):
                let data = Data(output.utf8)
                try BoneToolSchemaValidator.validate(arguments: data, against: schema)
                return .structured(.init(data: data))
            }
        } catch let error as BoneLlamaAdapterError {
            throw error
        } catch {
            throw BoneLlamaAdapterError.invalidToolCallingResponse
        }
    }
}
