import Foundation

struct BoneProviderOutputConstraintAdapterIdentity: Equatable, Sendable {
    let id: String
    let version: String
}

protocol BoneProviderOutputConstraintAdapter: Sendable {
    var identity: BoneProviderOutputConstraintAdapterIdentity { get }
    func supports(_ constraint: BoneInferenceOutputConstraint) -> Bool
    func requestFields(for constraint: BoneInferenceOutputConstraint) throws -> [String: Any]
    func response(
        from providerPayload: Data,
        constraint: BoneInferenceOutputConstraint
    ) throws -> BoneInferenceResponse
}

enum BoneProviderOutputConstraintSupport {
    static let wrapperProperty = "value"

    static func wrappedSchema(
        for constraint: BoneInferenceOutputConstraint
    ) throws -> [String: Any] {
        let valueSchema: BoneToolSchema
        switch try constraint.validated() {
        case let .jsonSchema(schema): valueSchema = schema
        case let .enumChoice(values):
            valueSchema = .string(enumValues: values, minimumLength: nil, maximumLength: nil)
        }
        guard supportsStrictProviderDialect(valueSchema) else {
            throw BoneInferenceError.invalidOutputConstraint
        }
        return [
            "type": "object",
            "properties": [wrapperProperty: try schemaObject(valueSchema)],
            "required": [wrapperProperty],
            "additionalProperties": false,
        ]
    }

    static func response(
        from providerPayload: Data,
        constraint: BoneInferenceOutputConstraint
    ) throws -> BoneInferenceResponse {
        let wrapper: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: providerPayload) as? [String: Any],
                  object.count == 1,
                  let value = object[wrapperProperty] else {
                throw BoneInferenceTransportError.invalidResponse
            }
            wrapper = object
            _ = wrapper
            let data: Data
            switch constraint {
            case .enumChoice:
                guard let text = value as? String else {
                    throw BoneInferenceTransportError.invalidResponse
                }
                data = Data(text.utf8)
            case .jsonSchema:
                data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
            }
            return try BoneInferenceOutputConstraintResult.response(from: data, constraint: constraint)
        } catch let error as BoneInferenceTransportError {
            throw error
        } catch {
            throw BoneInferenceTransportError.invalidResponse
        }
    }

    static func supportsStrictProviderDialect(_ schema: BoneToolSchema) -> Bool {
        switch schema {
        case let .object(properties, required, additionalProperties):
            return !additionalProperties
                && Set(required) == Set(properties.keys)
                && properties.values.allSatisfy(supportsStrictProviderDialect)
        case let .array(items, minimumItems, maximumItems):
            return minimumItems == nil && maximumItems == nil
                && supportsStrictProviderDialect(items)
        case let .string(_, minimumLength, maximumLength):
            return minimumLength == nil && maximumLength == nil
        case .integer, .number, .boolean:
            return true
        case let .taggedUnion(_, variants):
            return variants.allSatisfy(supportsStrictProviderDialect)
        }
    }

    static func schemaObject(_ value: BoneToolSchema) throws -> [String: Any] {
        guard supportsStrictProviderDialect(value) else {
            throw BoneInferenceError.invalidOutputConstraint
        }
        switch value {
        case let .object(properties, required, additionalProperties):
            return [
                "type": "object",
                "properties": try properties.mapValues(schemaObject),
                "required": required,
                "additionalProperties": additionalProperties,
            ]
        case let .array(items, _, _):
            return ["type": "array", "items": try schemaObject(items)]
        case let .string(enumValues, _, _):
            var result: [String: Any] = ["type": "string"]
            if !enumValues.isEmpty { result["enum"] = enumValues }
            return result
        case let .integer(minimum, maximum):
            var result: [String: Any] = ["type": "integer"]
            if let minimum { result["minimum"] = minimum }
            if let maximum { result["maximum"] = maximum }
            return result
        case let .number(minimum, maximum):
            var result: [String: Any] = ["type": "number"]
            if let minimum { result["minimum"] = minimum }
            if let maximum { result["maximum"] = maximum }
            return result
        case .boolean:
            return ["type": "boolean"]
        case let .taggedUnion(discriminator, variants):
            return [
                "oneOf": try variants.map(schemaObject),
                "discriminator": ["propertyName": discriminator],
            ]
        }
    }
}
