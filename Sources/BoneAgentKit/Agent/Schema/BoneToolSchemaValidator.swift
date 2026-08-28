import Foundation

/// Tool Schema 定义和模型参数的本地验证器。
public enum BoneToolSchemaValidator {
    public static let maximumEncodedSchemaByteCount = 64 * 1_024
    public static let maximumArgumentsByteCount = 1_048_576
    public static let maximumSchemaDepth = 16
    public static let maximumObjectPropertyCount = 128
    public static let maximumUnionVariantCount = 16

    /// 验证 Schema 本身的一致性和资源边界。
    public static func validateDefinition(_ schema: BoneToolSchema) throws {
        try validateDefinition(schema, depth: 0)
        let data = try JSONEncoder().encode(schema)
        guard data.count <= maximumEncodedSchemaByteCount else {
            throw BoneToolSchemaError.schemaTooLarge
        }
    }

    /// 先验证 JSON 边界，再按 Schema 验证参数。
    public static func validate(arguments: Data, against schema: BoneToolSchema) throws {
        guard arguments.count <= maximumArgumentsByteCount else {
            throw BoneToolSchemaError.argumentsTooLarge
        }
        try validateDefinition(schema)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: arguments, options: [.fragmentsAllowed])
        } catch {
            throw BoneToolSchemaError.argumentsMismatch
        }
        guard matches(value, schema: schema) else {
            throw BoneToolSchemaError.argumentsMismatch
        }
    }
}

private extension BoneToolSchemaValidator {
    static func validateDefinition(_ schema: BoneToolSchema, depth: Int) throws {
        guard depth <= maximumSchemaDepth else { throw BoneToolSchemaError.invalidSchema }
        switch schema {
        case let .object(properties, required, _):
            guard properties.count <= maximumObjectPropertyCount,
                  Set(required).count == required.count,
                  required.allSatisfy(properties.keys.contains),
                  properties.keys.allSatisfy(validFieldName) else {
                throw BoneToolSchemaError.invalidSchema
            }
            for child in properties.values {
                try validateDefinition(child, depth: depth + 1)
            }
        case let .array(items, minimumItems, maximumItems):
            guard validBounds(minimumItems, maximumItems) else {
                throw BoneToolSchemaError.invalidSchema
            }
            try validateDefinition(items, depth: depth + 1)
        case let .string(enumValues, minimumLength, maximumLength):
            guard validBounds(minimumLength, maximumLength),
                  Set(enumValues).count == enumValues.count,
                  enumValues.allSatisfy({ !$0.isEmpty }) else {
                throw BoneToolSchemaError.invalidSchema
            }
        case let .integer(minimum, maximum):
            guard validBounds(minimum, maximum) else { throw BoneToolSchemaError.invalidSchema }
        case let .number(minimum, maximum):
            guard validBounds(minimum, maximum),
                  minimum?.isFinite != false,
                  maximum?.isFinite != false else {
                throw BoneToolSchemaError.invalidSchema
            }
        case .boolean:
            break
        case let .taggedUnion(discriminator, variants):
            guard validFieldName(discriminator),
                  (1...maximumUnionVariantCount).contains(variants.count) else {
                throw BoneToolSchemaError.invalidSchema
            }
            var discriminatorValues = Set<String>()
            for variant in variants {
                guard case let .object(properties, required, additionalProperties) = variant,
                      required.contains(discriminator),
                      additionalProperties == false,
                      case let .string(values, _, _) = properties[discriminator],
                      values.count == 1,
                      discriminatorValues.insert(values[0]).inserted else {
                    throw BoneToolSchemaError.invalidSchema
                }
                try validateDefinition(variant, depth: depth + 1)
            }
        }
    }

    static func matches(_ value: Any, schema: BoneToolSchema) -> Bool {
        switch schema {
        case let .object(properties, required, additionalProperties):
            guard let object = value as? [String: Any],
                  required.allSatisfy({ object[$0] != nil }) else { return false }
            if !additionalProperties && !Set(object.keys).isSubset(of: Set(properties.keys)) {
                return false
            }
            return object.allSatisfy { key, child in
                guard let childSchema = properties[key] else { return additionalProperties }
                return matches(child, schema: childSchema)
            }
        case let .array(items, minimumItems, maximumItems):
            guard let values = value as? [Any],
                  contains(values.count, minimum: minimumItems, maximum: maximumItems) else {
                return false
            }
            return values.allSatisfy { matches($0, schema: items) }
        case let .string(enumValues, minimumLength, maximumLength):
            guard let string = value as? String,
                  contains(string.count, minimum: minimumLength, maximum: maximumLength) else {
                return false
            }
            return enumValues.isEmpty || enumValues.contains(string)
        case let .integer(minimum, maximum):
            guard let number = value as? NSNumber,
                  !isBoolean(number),
                  CFNumberIsFloatType(number) == false else { return false }
            return contains(number.intValue, minimum: minimum, maximum: maximum)
        case let .number(minimum, maximum):
            guard let number = value as? NSNumber, !isBoolean(number) else { return false }
            return contains(number.doubleValue, minimum: minimum, maximum: maximum)
        case .boolean:
            guard let number = value as? NSNumber else { return false }
            return isBoolean(number)
        case let .taggedUnion(discriminator, variants):
            guard let object = value as? [String: Any], object[discriminator] is String else {
                return false
            }
            return variants.filter { matches(value, schema: $0) }.count == 1
        }
    }

    static func validFieldName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F
        }
    }

    static func validBounds<T: Comparable & AdditiveArithmetic>(_ minimum: T?, _ maximum: T?) -> Bool {
        if let minimum, minimum < .zero { return false }
        if let maximum, maximum < .zero { return false }
        if let minimum, let maximum, minimum > maximum { return false }
        return true
    }

    static func contains<T: Comparable>(_ value: T, minimum: T?, maximum: T?) -> Bool {
        if let minimum, value < minimum { return false }
        if let maximum, value > maximum { return false }
        return true
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
