import CryptoKit
import Foundation

/// 为能力身份提供显式版本化、确定性的 Tool Schema 编码。
///
/// 此格式独立于 `BoneToolSchema` 的自动 `Codable` 表示。变更 wire 结构或排序规则时，
/// 必须提升 `formatVersion`，使既有能力验证证据失效。
public enum BoneToolSchemaCanonicalEncoder {
    public static let formatVersion = 1

    public static func encode(_ schema: BoneToolSchema) throws -> Data {
        try BoneToolSchemaValidator.validateDefinition(schema)
        var writer = CanonicalWriter()
        writer.append("{\"formatVersion\":")
        writer.append(String(formatVersion))
        writer.append(",\"schema\":")
        try writer.append(schema)
        writer.append("}")
        return Data(writer.value.utf8)
    }

    public static func digest(_ schema: BoneToolSchema) throws -> String {
        SHA256.hash(data: try encode(schema)).map { String(format: "%02x", $0) }.joined()
    }
}

private struct CanonicalWriter {
    var value = ""

    mutating func append(_ fragment: String) {
        value.append(fragment)
    }

    mutating func append(_ schema: BoneToolSchema) throws {
        switch schema {
        case let .object(properties, required, additionalProperties):
            append("{\"type\":\"object\",\"properties\":[")
            let keys = properties.keys.sorted(by: Self.utf8Less)
            for (index, key) in keys.enumerated() {
                if index > 0 { append(",") }
                append("[")
                appendJSONString(key)
                append(",")
                guard let child = properties[key] else { throw BoneToolSchemaError.invalidSchema }
                try append(child)
                append("]")
            }
            append("],\"required\":[")
            for (index, key) in required.sorted(by: Self.utf8Less).enumerated() {
                if index > 0 { append(",") }
                appendJSONString(key)
            }
            append("],\"additionalProperties\":")
            append(additionalProperties ? "true" : "false")
            append("}")

        case let .array(items, minimumItems, maximumItems):
            append("{\"type\":\"array\",\"items\":")
            try append(items)
            appendOptionalInteger(name: "minimumItems", value: minimumItems)
            appendOptionalInteger(name: "maximumItems", value: maximumItems)
            append("}")

        case let .string(enumValues, minimumLength, maximumLength):
            append("{\"type\":\"string\",\"enum\":[")
            for (index, item) in enumValues.enumerated() {
                if index > 0 { append(",") }
                appendJSONString(item)
            }
            append("]")
            appendOptionalInteger(name: "minimumLength", value: minimumLength)
            appendOptionalInteger(name: "maximumLength", value: maximumLength)
            append("}")

        case let .integer(minimum, maximum):
            append("{\"type\":\"integer\"")
            appendOptionalInteger(name: "minimum", value: minimum)
            appendOptionalInteger(name: "maximum", value: maximum)
            append("}")

        case let .number(minimum, maximum):
            append("{\"type\":\"number\"")
            appendOptionalDouble(name: "minimum", value: minimum)
            appendOptionalDouble(name: "maximum", value: maximum)
            append("}")

        case .boolean:
            append("{\"type\":\"boolean\"}")

        case let .taggedUnion(discriminator, variants):
            append("{\"type\":\"taggedUnion\",\"discriminator\":")
            appendJSONString(discriminator)
            append(",\"variants\":[")
            let sorted = try variants.sorted {
                try Self.discriminatorValue($0, discriminator: discriminator)
                    .utf8.lexicographicallyPrecedes(
                        Self.discriminatorValue($1, discriminator: discriminator).utf8
                    )
            }
            for (index, variant) in sorted.enumerated() {
                if index > 0 { append(",") }
                try append(variant)
            }
            append("]}")
        }
    }

    mutating func appendOptionalInteger(name: String, value: Int?) {
        guard let value else { return }
        append(",\"")
        append(name)
        append("\":")
        append(String(value))
    }

    mutating func appendOptionalDouble(name: String, value: Double?) {
        guard let value else { return }
        append(",\"")
        append(name)
        append("\":")
        append(String(value))
    }

    mutating func appendJSONString(_ string: String) {
        append("\"")
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22: append("\\\"")
            case 0x5C: append("\\\\")
            case 0x08: append("\\b")
            case 0x0C: append("\\f")
            case 0x0A: append("\\n")
            case 0x0D: append("\\r")
            case 0x09: append("\\t")
            case 0x00...0x1F:
                append(String(format: "\\u%04x", scalar.value))
            default:
                append(String(scalar))
            }
        }
        append("\"")
    }

    static func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    static func discriminatorValue(
        _ schema: BoneToolSchema,
        discriminator: String
    ) throws -> String {
        guard case let .object(properties, _, _) = schema,
              case let .string(values, _, _)? = properties[discriminator],
              values.count == 1 else {
            throw BoneToolSchemaError.invalidSchema
        }
        return values[0]
    }
}
